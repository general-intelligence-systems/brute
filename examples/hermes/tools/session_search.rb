# frozen_string_literal: true

require "json"

module HermesTools
  # session_search — cross-session recall. Port of hermes-agent
  # tools/session_search_tool.py (single-shape tool; mode inferred from args):
  #
  #   discover: pass query (+ role_filter, sort, limit clamp [1,10])
  #   scroll:   session_id + around_message_id (+ window)
  #   read:     session_id alone → dump the whole session
  #   browse:   nothing → recent sessions
  #
  # The store is injected per turn by Hermes::Middleware::SessionStore.
  class SessionSearch < Brute::Tool
    description "Search past conversations. Discover by query, scroll around a message, " \
                "read a whole session, or browse recent sessions."
    params({
      "type" => "object",
      "properties" => {
        "query" => { "type" => "string", "description" => "FTS query (discover shape)." },
        "role_filter" => { "type" => "string", "description" => "Comma-separated roles to include (e.g. 'user,assistant')." },
        "limit" => { "type" => "integer", "description" => "Max results (1-10, default 3).", "default" => 3 },
        "session_id" => { "type" => "string", "description" => "Session to read/scroll." },
        "around_message_id" => { "type" => "integer", "description" => "Anchor message id (scroll shape)." },
        "window" => { "type" => "integer", "description" => "Messages around the anchor (default 5).", "default" => 5 },
        "sort" => { "type" => "string", "enum" => %w[newest oldest], "description" => "Result order (default newest)." },
      },
      "required" => [],
    })

    def initialize(store = nil, current_session_id: nil)
      @store = store
      @current_session_id = current_session_id
    end

    def name = "session_search"

    def execute(query: nil, role_filter: nil, limit: 3, session_id: nil,
                around_message_id: nil, window: 5, sort: nil, **_rest)
      return err("Session store unavailable.") unless @store

      limit = [[limit.to_i, 1].max, 10].min
      limit = 3 if limit.zero?

      # Scroll wins over read/discovery (an explicit anchor).
      if session_id && around_message_id
        rows = @store.get_messages_around(session_id, around_message_id, window: window)
        return JSON.dump("success" => true, "shape" => "scroll", "messages" => rows.map { |r| fmt_row(r) })
      end

      # Read: a session_id with no anchor dumps the whole session.
      if session_id
        session = @store.get_session(session_id)
        return err("session '#{session_id}' not found") unless session

        rows = @store.get_messages(session_id)
        return JSON.dump(
          "success" => true, "shape" => "read", "session" => session.transform_keys(&:to_s),
          "messages" => rows.map { |r| fmt_row(r) },
        )
      end

      # Browse: no query → recent sessions.
      if query.to_s.strip.empty?
        sessions = @store.recent_sessions(limit: limit).map do |s|
          s.slice(:id, :source, :model, :started_at, :last_activity_at, :message_count, :title).transform_keys(&:to_s)
        end
        return JSON.dump("success" => true, "shape" => "browse", "sessions" => sessions)
      end

      # Discover.
      roles = role_filter.to_s.split(",").map(&:strip).reject(&:empty?)
      rows = @store.search(query, role_filter: roles.empty? ? nil : roles, limit: limit, sort: sort)
      JSON.dump(
        "success" => true, "shape" => "discover", "query" => query,
        "count" => rows.size,
        "results" => rows.map { |r| fmt_row(r) },
        "hint" => "Use session_id + around_message_id to scroll around a hit.",
      )
    end

    private

    def fmt_row(row)
      {
        "id" => row[:id],
        "session_id" => row[:session_id],
        "role" => row[:role],
        "timestamp" => row[:timestamp],
        "snippet" => row[:content].to_s.gsub("\n", " ")[0, 200],
      }
    end

    def err(message)
      JSON.dump("success" => false, "error" => message)
    end
  end
end
