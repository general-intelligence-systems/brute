# frozen_string_literal: true

require "json"

# Seahorse retrieval — pkg/seahorse/short_retrieval.go (Grep + ExpandMessages).
module Seahorse
  class Retrieval
    def initialize(store:, session:)
      @store = store
      @session = session
    end

    # "6h" | "7d" | "2w" | "1m"(=30d) → seconds; nil on invalid.
    def self.parse_last(value)
      match = value.to_s.match(/\A(\d+)([hdwm])\z/)
      return nil unless match

      n = match[1].to_i
      case match[2]
      when "h" then n * 3600
      when "d" then n * 86_400
      when "w" then n * 604_800
      when "m" then n * 2_592_000
      end
    end

    def grep(pattern:, scope: "both", role: nil, last: nil, all_conversations: false,
             since: nil, before: nil, limit: 20)
      raise "grep: pattern is required" if pattern.to_s.empty?

      limit = 20 if limit.to_i <= 0
      if last.to_s != ""
        seconds = self.class.parse_last(last)
        raise "grep: invalid last: invalid duration format: #{last.inspect} (use format like 6h, 7d, 2w, 1m)" unless seconds

        since = (Time.now.utc - seconds).strftime("%Y-%m-%d %H:%M:%S")
      end

      conv = @store.conversation_id(@session)
      clauses, params = like_clauses(pattern)

      result = { "success" => true, "summaries" => [], "messages" => [] }
      scope = "both" if scope.to_s.empty?

      if %w[both summary].include?(scope)
        rows = if clauses.nil? && @store.fts?
                 fts_rows("summaries_fts", pattern, limit).filter_map do |r|
                   sum = @store.summary(r["ref"])
                   sum && { "id" => sum["summary_id"], "content" => sum["content"], "depth" => sum["depth"],
                            "kind" => sum["kind"], "conversationId" => conv, "rank" => r["rank"] }
                 end
               else
                 @store.search_summaries(conv_id: conv, like_clauses: clauses || [], params: params,
                                         since: since, before: before, limit: limit,
                                         all_conversations: all_conversations).map do |row|
                   { "id" => row["summary_id"], "content" => row["content"], "depth" => row["depth"],
                     "kind" => row["kind"], "conversationId" => row["conversation_id"] || conv }
                 end
               end
        result["summaries"] = rows.first(limit)
        result["totalSummaries"] = rows.size
      end

      if %w[both message].include?(scope)
        rows = if clauses.nil? && @store.fts?
                 fts_rows("messages_fts", pattern, limit).filter_map do |r|
                   msg = @store.message(r["ref"])
                   msg && { "id" => msg["message_id"].to_s, "snippet" => snippet(msg["content"], pattern),
                            "role" => msg["role"], "conversationId" => conv, "rank" => r["rank"] }
                 end
               else
                 @store.search_messages(conv_id: conv, like_clauses: clauses || [], params: params,
                                        role: role, since: since, before: before, limit: limit,
                                        all_conversations: all_conversations).map do |row|
                   { "id" => row["message_id"].to_s, "snippet" => snippet(row["content"], pattern),
                     "role" => row["role"], "conversationId" => conv }
                 end
               end
        result["messages"] = rows.first(limit)
        result["totalMessages"] = rows.size
      end

      if result["summaries"].empty? && result["messages"].empty?
        result["hint"] = "No matches. Try: %keyword% for fuzzy search"
      end
      result
    end

    def expand(message_ids)
      messages = []
      tokens = 0
      message_ids.each do |id|
        record = @store.message(id.to_i)
        next unless record

        tokens += record["token_count"]
        parts = (record["parts"] || []).map do |p|
          case p["type"]
          when "text" then { "type" => "text", "text" => p["text"] }
          when "tool_use" then { "type" => "tool_use", "name" => p["name"], "arguments" => p["arguments"], "toolCallId" => p["tool_call_id"] }
          when "tool_result" then { "type" => "tool_result", "toolCallId" => p["tool_call_id"] } # content omitted upstream
          when "media" then { "type" => "media", "mediaUri" => p["media_uri"], "mimeType" => p["mime_type"] }
          end.compact
        end
        messages << { "id" => record["message_id"].to_s, "content" => record["content"], "parts" => parts }
      end
      { "success" => true, "tokenCount" => tokens, "messages" => messages }
    end

    private

    def fts_rows(table, pattern, limit)
      @store.fts_search(table, fts_query(pattern), limit: limit)
    end

    # Plain words/AND/OR/NOT → an FTS5 query; %..% patterns are handled by LIKE.
    def fts_query(pattern)
      pattern.scan(/"[^"]+"|\S+/).map { |t| t.start_with?('"') ? t : "\"#{t.gsub('"', '')}\"" }.join(" ")
    end

    # Returns nil when the pattern uses explicit % wildcards with no AND/OR/NOT
    # semantics needed beyond LIKE; builds [clauses, params] otherwise.
    def like_clauses(pattern)
      return [["content LIKE ?"], [pattern]] if pattern.include?("%")

      clauses = []
      params = []
      or_groups = pattern.split(/\s+OR\s+/i)
      or_clauses = or_groups.map do |group|
        tokens = group.split(/\s+/)
        negate = []
        positives = []
        tokens.each do |token|
          if token.match?(/\AAND\z/i)
            next
          elsif (m = token.match(/\ANOT[:\s]*(.+)/i))
            negate << m[1]
          else
            positives << token
          end
        end
        sub = []
        positives.each do |token|
          sub << "content LIKE ?"
          params << "%#{token}%"
        end
        negate.each do |token|
          sub << "content NOT LIKE ?"
          params << "%#{token}%"
        end
        sub.empty? ? "1=1" : "(#{sub.join(" AND ")})"
      end
      clauses << "(#{or_clauses.join(" OR ")})"
      [clauses, params]
    end

    def snippet(content, pattern)
      text = content.to_s
      term = pattern.gsub("%", "").split(/\s+/).reject { |t| t.match?(/\A(AND|OR|NOT)\z/i) }.first.to_s
      idx = text.downcase.index(term.downcase) || 0
      start = [idx - 80, 0].max
      text[start, 160].to_s
    end
  end
end
