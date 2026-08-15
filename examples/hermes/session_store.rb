# frozen_string_literal: true

require "extralite"
require "json"
require "fileutils"
require "securerandom"

module Hermes
  # Durable session storage on SQLite via extralite — port of hermes-agent's
  # SessionDB core (hermes_state.py), workspace-scoped:
  #
  #   sessions(id, source, model, system_prompt, parent_session_id,
  #            started_at, ended_at, end_reason, message_count,
  #            tool_call_count, cwd, last_activity_at, archived, pinned)
  #   messages(id AUTOINCREMENT, session_id, role, content, tool_call_id,
  #            tool_calls, timestamp, active, api_content, display_kind)
  #   messages_fts — FTS5 over content, kept in sync on insert
  #
  # Ported semantics: append-only writes in one transaction per batch;
  # insertion-order reads (id, not wall-clock); active-only by default;
  # soft delete via active=0; system-prompt snapshot on the session row;
  # compression rotation via parent_session_id; FTS5 search with role
  # filter + sort + LIKE fallback when FTS is unavailable.
  class SessionStore
    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL DEFAULT 'cli',
        model TEXT,
        system_prompt TEXT,
        parent_session_id TEXT REFERENCES sessions(id),
        started_at REAL NOT NULL,
        ended_at REAL,
        end_reason TEXT,
        message_count INTEGER DEFAULT 0,
        tool_call_count INTEGER DEFAULT 0,
        cwd TEXT,
        title TEXT,
        last_activity_at REAL,
        archived INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        role TEXT NOT NULL,
        content TEXT,
        tool_call_id TEXT,
        tool_calls TEXT,
        timestamp REAL NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        api_content TEXT,
        display_kind TEXT
      );

      CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, id);
    SQL

    FTS_SCHEMA = <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        content, session_id UNINDEXED, role UNINDEXED, message_id UNINDEXED
      );
    SQL

    attr_reader :path

    def initialize(path:)
      @path = path
      FileUtils.mkdir_p(File.dirname(path))
      @db = Extralite::Database.new(path)
      @db.execute(SCHEMA)
      @fts = init_fts
    end

    def close
      @db.close
    end

    # -- Sessions ---------------------------------------------------------------

    def create_session(id: nil, source: "cli", model: nil, cwd: nil, title: nil)
      id ||= SecureRandom.hex(8)
      @db.execute(
        "INSERT OR IGNORE INTO sessions (id, source, model, started_at, cwd, last_activity_at, title) VALUES (?, ?, ?, ?, ?, ?, ?)",
        id, source, model, now, cwd, now, title,
      )
      id
    end

    def get_session(id)
      @db.query("SELECT * FROM sessions WHERE id = ?", id).to_a.first
    end

    def update_system_prompt(id, prompt)
      @db.execute("UPDATE sessions SET system_prompt = ? WHERE id = ?", prompt, id)
    end

    def end_session(id, reason:)
      @db.execute("UPDATE sessions SET ended_at = ?, end_reason = ? WHERE id = ?", now, reason, id)
    end

    # Compression rotation: end the parent into a new child session.
    def rotate(old_id, new_id: nil)
      end_session(old_id, reason: "compression")
      parent = get_session(old_id)
      new_id ||= SecureRandom.hex(8)
      create_session(id: new_id, source: parent&.dig(:source) || "cli", model: parent&.dig(:model), cwd: parent&.dig(:cwd))
      @db.execute("UPDATE sessions SET parent_session_id = ? WHERE id = ?", old_id, new_id)
      new_id
    end

    # -- Messages ---------------------------------------------------------------

    # Append one message. Returns the row id.
    def append_message(session_id:, role:, content: nil, tool_call_id: nil, tool_calls: nil, timestamp: nil, api_content: nil, display_kind: nil)
      ts = timestamp || now
      tool_calls_json = tool_calls && JSON.dump(tool_calls)
      @db.execute(
        "INSERT INTO messages (session_id, role, content, tool_call_id, tool_calls, timestamp, api_content, display_kind)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        session_id, role.to_s, content&.to_s, tool_call_id, tool_calls_json, ts, api_content&.to_s, display_kind,
      )
      id = @db.last_insert_row_id rescue @db.query("SELECT last_insert_rowid() AS id").to_a.first[:id]
      fts_insert(id, session_id, role.to_s, content) if @fts && content
      bump_counters(session_id, role)
      id
    end

    # Batch append in ONE transaction (hermes: one txn per flush).
    def append_messages_batch(session_id:, messages:)
      @db.transaction do
        messages.map { |m| append_message(session_id: session_id, **m) }
      end
    end

    # Insertion-order read, active-only by default.
    def get_messages(session_id, include_inactive: false, limit: nil, latest: false, after_id: nil)
      sql = +"SELECT * FROM messages WHERE session_id = ?"
      params = [session_id]
      sql += " AND active = 1" unless include_inactive
      if after_id
        sql += " AND id > ?"
        params << after_id
      end
      sql += " ORDER BY id #{latest ? 'DESC' : 'ASC'}"
      if limit
        sql += " LIMIT ?"
        params << limit
      end
      rows = @db.query(sql, *params).to_a
      rows.reverse! if latest
      rows
    end

    # Window around an anchor message id (the scroll shape's backend).
    def get_messages_around(session_id, message_id, window: 5)
      @db.query(
        "SELECT * FROM messages WHERE session_id = ? AND id BETWEEN ? AND ? AND active = 1 ORDER BY id ASC",
        session_id, message_id - window, message_id + window,
      ).to_a
    end

    def recent_sessions(limit: 5)
      @db.query(
        "SELECT * FROM sessions WHERE archived = 0 ORDER BY COALESCE(last_activity_at, started_at) DESC LIMIT ?",
        limit,
      ).to_a
    end

    # -- Search -------------------------------------------------------------------

    # FTS5 primary; LIKE boolean fallback when FTS is unavailable.
    def search(query, role_filter: nil, limit: 20, sort: nil, exclude_compaction: true)
      return [] if query.to_s.strip.empty?

      if @fts
        fts_search(query, role_filter: role_filter, limit: limit, sort: sort, exclude_compaction: exclude_compaction)
      else
        like_search(query, role_filter: role_filter, limit: limit, sort: sort)
      end
    end

    private

    def init_fts
      @db.execute(FTS_SCHEMA)
      true
    rescue StandardError
      false
    end

    def fts_insert(message_id, session_id, role, content)
      @db.execute("INSERT INTO messages_fts (message_id, session_id, role, content) VALUES (?, ?, ?, ?)",
                  message_id, session_id, role, content.to_s)
    rescue StandardError
      @fts = false
    end

    # Only word tokens and spaces survive FTS5's query syntax (hermes
    # sanitizes the same way before MATCH).
    def sanitize_fts_query(query)
      query.to_s.scan(/[\p{Alnum}_]+/).join(" ")
    end

    def fts_search(query, role_filter:, limit:, sort:, exclude_compaction:)
      sanitized = sanitize_fts_query(query)
      return [] if sanitized.empty?

      sql = +"SELECT m.* FROM messages_fts f JOIN messages m ON m.id = f.message_id WHERE messages_fts MATCH ?"
      params = [sanitized]
      sql += " AND m.active = 1"
      if exclude_compaction
        sql += " AND m.content NOT LIKE '[CONTEXT COMPACTION%' AND m.content NOT LIKE '[CONTEXT SUMMARY]%'"
      end
      if role_filter && !role_filter.empty?
        sql += " AND m.role IN (#{role_filter.map { '?' }.join(',')})"
        params.concat(role_filter)
      end
      sql += " ORDER BY m.id #{sort == 'oldest' ? 'ASC' : 'DESC'} LIMIT ?"
      params << limit
      @db.query(sql, *params).to_a
    rescue StandardError
      like_search(query, role_filter: role_filter, limit: limit, sort: sort)
    end

    def like_search(query, role_filter:, limit:, sort:)
      terms = sanitize_fts_query(query).split
      return [] if terms.empty?

      sql = +"SELECT * FROM messages WHERE active = 1"
      params = []
      terms.each do |term|
        sql += " AND content LIKE ?"
        params << "%#{term}%"
      end
      if role_filter && !role_filter.empty?
        sql += " AND role IN (#{role_filter.map { '?' }.join(',')})"
        params.concat(role_filter)
      end
      sql += " ORDER BY id #{sort == 'oldest' ? 'ASC' : 'DESC'} LIMIT ?"
      params << limit
      @db.query(sql, *params).to_a
    end

    def bump_counters(session_id, role)
      tool_inc = role.to_s == "tool" ? 1 : 0
      @db.execute(
        "UPDATE sessions SET message_count = message_count + 1, tool_call_count = tool_call_count + ?, last_activity_at = ? WHERE id = ?",
        tool_inc, now, session_id,
      )
    end

    def now = Time.now.to_f
  end
end
