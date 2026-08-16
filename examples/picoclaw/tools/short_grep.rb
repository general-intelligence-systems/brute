# frozen_string_literal: true

require "json"
require "time"

# short_grep — picoclaw's pkg/seahorse/tool_grep.go. Full-text/LIKE search
# over summaries and messages in the seahorse store. Registered only when
# agents.defaults.context_manager == "seahorse".
class ShortGrep < Brute::Tool
  description <<~DESC.chomp
    Search summaries and messages for matching content.

    Pattern syntax:
    - Words: "authentication" - matches content containing this word
    - AND: "auth AND login" - matches content with both words
    - OR: "auth OR signin" - matches content with either word
    - NOT: "bug NOT fixed" - matches "bug" but excludes "fixed"
    - Wildcard: "%auth%" - matches any text containing "auth" (e.g., "auth", "authentication")

    Each summary has a "depth" field:
    - depth 0: Created from messages, most detailed
    - depth 1+: Created from other summaries, more compressed but covers longer time

    Parameters:
    - pattern (required): Search pattern
    - scope: "both" (default), "summary", or "message" - what to search
    - role: "user", "assistant", or omit for all - filter by message role
    - last: Time shortcut like "6h", "7d", "2w", "1m" (hours/days/weeks/months)
    - all_conversations: Search all conversations (default: current only)
    - since: ISO8601 timestamp, content after this time
    - before: ISO8601 timestamp, content before this time
    - limit: Max results (default: 20)

    Returns:
    {
      "success": true,
      "summaries": [{"id": "sum_abc", "content": "...", "depth": 0, "kind": "leaf", "conversationId": 1, "rank": -0.5}],
      "messages": [{"id": "10", "snippet": "...matched...", "role": "user", "conversationId": 1, "rank": -1.2}],
      "totalSummaries": 5,
      "totalMessages": 10,
      "hint": "No matches. Try: %keyword% for fuzzy search"
    }

    Rank field (FTS5 mode only): bm25 relevance score, negative value where more negative = higher relevance.
    Examples: -5=excellent, -2=good, -0.5=partial. LIKE mode (%pattern%) has no rank.

    Examples:
      {"pattern": "authentication"}
      {"pattern": "bug AND login"}
      {"pattern": "%snake%"}
      {"pattern": "project", "scope": "summary"}
      {"pattern": "error", "role": "assistant", "last": "7d"}
      {"pattern": "error", "all_conversations": true}
  DESC
  params({
    "type" => "object",
    "properties" => {
      "pattern" => { "type" => "string", "description" => "Search pattern. Supports: words, AND/OR/NOT operators, % wildcard" },
      "scope" => { "type" => "string", "enum" => %w[both summary message], "description" => "What to search: 'both' (default), 'summary', or 'message'" },
      "role" => { "type" => "string", "enum" => %w[user assistant], "description" => "Filter by message role (default: all roles)" },
      "last" => { "type" => "string", "description" => "Time shortcut: '6h' (6 hours), '7d' (7 days), '2w' (2 weeks), '1m' (1 month)" },
      "all_conversations" => { "type" => "boolean", "description" => "Search across all conversations (default: searches current conversation only)" },
      "since" => { "type" => "string", "description" => "ISO8601 timestamp, only return content after this time" },
      "before" => { "type" => "string", "description" => "ISO8601 timestamp, only return content before this time" },
      "limit" => { "type" => "integer", "description" => "Maximum number of results (default: 20)" },
    },
    "required" => ["pattern"],
  })

  def initialize(retrieval:)
    @retrieval = retrieval
  end

  def name = "short_grep"

  def execute(pattern: nil, scope: "both", role: nil, last: nil, all_conversations: false,
              since: nil, before: nil, limit: 20, **_args)
    return "pattern is required" if pattern.to_s.empty?
    return "since must be an ISO8601 timestamp" if bad_time?(since)
    return "before must be an ISO8601 timestamp" if bad_time?(before)

    result = @retrieval.grep(pattern: pattern, scope: scope, role: role, last: last,
                             all_conversations: all_conversations == true,
                             since: iso_time(since), before: iso_time(before), limit: limit.to_i)
    JSON.pretty_generate(result)
  rescue StandardError => e
    e.message
  end

  private

  def bad_time?(value)
    return false if value.to_s.empty?

    Time.iso8601(value)
    false
  rescue ArgumentError
    true
  end

  def iso_time(value)
    return nil if value.to_s.empty?

    Time.iso8601(value).utc.strftime("%Y-%m-%d %H:%M:%S")
  end
end
