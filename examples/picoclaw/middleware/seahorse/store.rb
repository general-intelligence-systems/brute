# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

# Seahorse store — picoclaw's pkg/seahorse/store.go + schema.go, on SQLite
# via extralite. Seven tables (conversations, messages, message_parts,
# summaries, summary_parents, summary_messages, context_items) plus FTS5
# virtual tables + sync triggers when the SQLite build has FTS5; otherwise
# search falls back to LIKE mode (upstream's %pattern% path becomes the only
# mode — noted delta from upstream, which hard-requires FTS5).
module Seahorse
  class Store
    ORDINAL_STEP = 100

    def initialize(path)
      FileUtils.mkdir_p(File.dirname(path))
      @db = Extralite::Database.new(path)
      @fts = false
      run_schema
    end

    def fts? = @fts

    def run_schema
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS conversations (
          conversation_id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_key     TEXT NOT NULL UNIQUE,
          created_at      TEXT NOT NULL DEFAULT (datetime('now')),
          updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS messages (
          message_id      INTEGER PRIMARY KEY AUTOINCREMENT,
          conversation_id INTEGER NOT NULL REFERENCES conversations(conversation_id),
          role            TEXT NOT NULL,
          content         TEXT NOT NULL DEFAULT '',
          model_name      TEXT NOT NULL DEFAULT '',
          reasoning_content TEXT NOT NULL DEFAULT '',
          token_count     INTEGER NOT NULL DEFAULT 0,
          created_at      TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS message_parts (
          part_id     INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id  INTEGER NOT NULL REFERENCES messages(message_id),
          type        TEXT NOT NULL,
          text        TEXT,
          name        TEXT,
          arguments   TEXT,
          tool_call_id TEXT,
          media_uri   TEXT,
          mime_type   TEXT,
          ordinal     INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS summaries (
          summary_id                TEXT PRIMARY KEY,
          conversation_id           INTEGER NOT NULL REFERENCES conversations(conversation_id),
          kind                      TEXT NOT NULL,
          depth                     INTEGER NOT NULL DEFAULT 0,
          content                   TEXT NOT NULL,
          token_count               INTEGER NOT NULL DEFAULT 0,
          earliest_at               TEXT,
          latest_at                 TEXT,
          descendant_count          INTEGER NOT NULL DEFAULT 0,
          descendant_token_count    INTEGER NOT NULL DEFAULT 0,
          source_message_token_count INTEGER NOT NULL DEFAULT 0,
          model                     TEXT,
          created_at                TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS summary_parents (
          summary_id        TEXT NOT NULL,
          parent_summary_id TEXT NOT NULL,
          PRIMARY KEY (summary_id, parent_summary_id)
        );
        CREATE TABLE IF NOT EXISTS summary_messages (
          summary_id TEXT NOT NULL,
          message_id INTEGER NOT NULL,
          ordinal    INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (summary_id, message_id)
        );
        CREATE TABLE IF NOT EXISTS context_items (
          conversation_id INTEGER NOT NULL,
          ordinal         INTEGER NOT NULL,
          item_type       TEXT NOT NULL,
          summary_id      TEXT,
          message_id      INTEGER,
          token_count     INTEGER NOT NULL DEFAULT 0,
          created_at      TEXT NOT NULL DEFAULT (datetime('now')),
          PRIMARY KEY (conversation_id, ordinal)
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id);
        CREATE INDEX IF NOT EXISTS idx_summaries_conversation ON summaries(conversation_id);
        CREATE INDEX IF NOT EXISTS idx_summaries_kind_depth ON summaries(conversation_id, kind, depth);
        CREATE INDEX IF NOT EXISTS idx_context_items_conv ON context_items(conversation_id, ordinal);
      SQL

      begin
        @db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS _fts5_check USING fts5(content)")
        @db.execute("DROP TABLE IF EXISTS _fts5_check")
        @db.execute(<<~SQL)
          CREATE VIRTUAL TABLE IF NOT EXISTS summaries_fts USING fts5(summary_id, content);
          CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(message_id, content);
          CREATE TRIGGER IF NOT EXISTS summaries_ai AFTER INSERT ON summaries BEGIN
            INSERT INTO summaries_fts (summary_id, content) VALUES (new.summary_id, new.content);
          END;
          CREATE TRIGGER IF NOT EXISTS summaries_ad AFTER DELETE ON summaries BEGIN
            DELETE FROM summaries_fts WHERE summary_id = old.summary_id;
          END;
          CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
            INSERT INTO messages_fts (message_id, content) VALUES (new.message_id, new.content);
          END;
          CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
            DELETE FROM messages_fts WHERE message_id = old.message_id;
          END;
        SQL
        @fts = true
      rescue StandardError
        @fts = false
      end
    end

    def close = @db.close

    # extralite returns symbol keys; the store speaks string keys.
    def query(sql, *params)
      @db.query(sql, *params).map { |row| row.transform_keys(&:to_s) }
    end

    # --- conversations --------------------------------------------------------

    def conversation_id(session_key)
      @db.execute("INSERT OR IGNORE INTO conversations (session_key) VALUES (?)", session_key)
      query("SELECT conversation_id FROM conversations WHERE session_key = ?", session_key)
        .first["conversation_id"]
    end

    def delete_conversation(conv_id)
      %w[messages summaries context_items].each do |table|
        @db.execute("DELETE FROM #{table} WHERE conversation_id = ?", conv_id)
      end
      @db.execute("DELETE FROM conversations WHERE conversation_id = ?", conv_id)
    end

    def message_count(conv_id)
      query("SELECT COUNT(*) AS n FROM messages WHERE conversation_id = ?", conv_id).first["n"]
    end

    # --- messages + parts -------------------------------------------------------

    def add_message(conv_id, role:, content:, token_count:, parts: [], created_at: nil)
       @db.execute(
        "INSERT INTO messages (conversation_id, role, content, token_count, created_at) VALUES (?, ?, ?, ?, COALESCE(?, datetime('now')))",
        conv_id, role, content, token_count, created_at,
      )
      message_id = query("SELECT last_insert_rowid() AS id").first["id"]
      parts.each_with_index do |part, i|
         @db.execute(
          "INSERT INTO message_parts (message_id, type, text, name, arguments, tool_call_id, media_uri, mime_type, ordinal) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
          message_id, part[:type], part[:text], part[:name], part[:arguments],
          part[:tool_call_id], part[:media_uri], part[:mime_type], i,
        )
      end
      append_context_item(conv_id, "message", message_id: message_id, token_count: token_count)
      message_id
    end

    def message(id)
      row = query("SELECT * FROM messages WHERE message_id = ?", id).first
      return nil unless row

      row["parts"] = query("SELECT * FROM message_parts WHERE message_id = ? ORDER BY ordinal", id)
      row
    end

    # --- context items ----------------------------------------------------------

    def append_context_item(conv_id, item_type, summary_id: nil, message_id: nil, token_count: 0)
      last = query("SELECT MAX(ordinal) AS o FROM context_items WHERE conversation_id = ?", conv_id).first["o"]
      ordinal = (last || 0) + ORDINAL_STEP
       @db.execute(
        "INSERT INTO context_items (conversation_id, ordinal, item_type, summary_id, message_id, token_count) VALUES (?, ?, ?, ?, ?, ?)",
        conv_id, ordinal, item_type, summary_id, message_id, token_count,
      )
    end

    def context_items(conv_id)
      query("SELECT * FROM context_items WHERE conversation_id = ? ORDER BY ordinal", conv_id)
    end

    def context_token_count(conv_id)
      query("SELECT COALESCE(SUM(token_count), 0) AS t FROM context_items WHERE conversation_id = ?", conv_id).first["t"]
    end

    def replace_context_range_with_summary(conv_id, from_ordinal, to_ordinal, summary_id, token_count)
       @db.execute(
        "DELETE FROM context_items WHERE conversation_id = ? AND ordinal >= ? AND ordinal <= ?",
        conv_id, from_ordinal, to_ordinal,
      )
       @db.execute(
        "INSERT INTO context_items (conversation_id, ordinal, item_type, summary_id, token_count) VALUES (?, ?, 'summary', ?, ?)",
        conv_id, from_ordinal, summary_id, token_count,
      )
    end

    # --- summaries ----------------------------------------------------------------

    def create_summary(conv_id, kind:, depth:, content:, token_count:, earliest_at: nil, latest_at: nil,
                       source_message_tokens: 0, descendant_count: 0, descendant_token_count: 0)
      id = "sum_#{SecureRandom.hex(8)}"
       @db.execute(
        "INSERT INTO summaries (conversation_id, summary_id, kind, depth, content, token_count, earliest_at, latest_at, descendant_count, descendant_token_count, source_message_token_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        conv_id, id, kind, depth, content, token_count, earliest_at, latest_at,
        descendant_count, descendant_token_count, source_message_tokens,
      )
      id
    end

    def summary(id)
      query("SELECT * FROM summaries WHERE summary_id = ?", id).first
    end

    def link_summary_to_messages(summary_id, message_ids)
      message_ids.each_with_index do |mid, i|
        @db.execute("INSERT OR IGNORE INTO summary_messages (summary_id, message_id, ordinal) VALUES (?, ?, ?)",
                    summary_id, mid, i)
      end
    end

    def link_summary_parents(summary_id, parent_ids)
      parent_ids.each do |pid|
        @db.execute("INSERT OR IGNORE INTO summary_parents (summary_id, parent_summary_id) VALUES (?, ?)",
                    summary_id, pid)
      end
    end

    def summary_parents(summary_id)
      query("SELECT parent_summary_id FROM summary_parents WHERE summary_id = ?", summary_id).map { |r| r["parent_summary_id"] }
    end

    def distinct_depths(conv_id)
       @db.execute(
        "SELECT DISTINCT s.depth AS depth FROM summaries s JOIN context_items c ON c.summary_id = s.summary_id WHERE c.conversation_id = ? ORDER BY s.depth",
        conv_id,
      ).map { |r| r["depth"] }
    end

    # The messages/summaries behind context items, resolved in order.
    def resolve_item(item)
      if item["item_type"] == "message"
        message(item["message_id"])
      else
        summary(item["summary_id"])
      end
    end

    # --- search -----------------------------------------------------------------

    def search_messages(conv_id:, like_clauses:, params:, role: nil, since: nil, before: nil, limit: 20, all_conversations: false)
      where = []
      bind = []
      unless all_conversations
        where << "conversation_id = ?"
        bind << conv_id
      end
      if role && !role.empty?
        where << "role = ?"
        bind << role
      end
      if since
        where << "created_at >= ?"
        bind << since
      end
      if before
        where << "created_at <= ?"
        bind << before
      end
      where += like_clauses
      bind += params
      sql = "SELECT message_id, role, content, created_at FROM messages"
      sql += " WHERE #{where.join(" AND ")}" if where.any?
      sql += " ORDER BY created_at DESC LIMIT ?"
      query(sql, *bind, limit.to_i + 1)
    end

    def search_summaries(conv_id:, like_clauses:, params:, since: nil, before: nil, limit: 20, all_conversations: false)
      where = []
      bind = []
      unless all_conversations
        where << "conversation_id = ?"
        bind << conv_id
      end
      if since
        where << "created_at >= ?"
        bind << since
      end
      if before
        where << "created_at <= ?"
        bind << before
      end
      where += like_clauses
      bind += params
      sql = "SELECT summary_id, kind, depth, content, created_at FROM summaries"
      sql += " WHERE #{where.join(" AND ")}" if where.any?
      sql += " ORDER BY created_at DESC LIMIT ?"
      query(sql, *bind, limit.to_i + 1)
    end

    # FTS5 path (when available): MATCH with the pattern as a query string.
    def fts_search(table, pattern, limit: 20)
       query(
        "SELECT #{table == "messages_fts" ? "message_id" : "summary_id"} AS ref, rank FROM #{table} WHERE #{table} MATCH ? ORDER BY rank LIMIT ?",
        pattern, limit,
      )
    rescue StandardError
      []
    end
  end
end
