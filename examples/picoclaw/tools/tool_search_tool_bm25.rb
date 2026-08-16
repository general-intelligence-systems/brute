# frozen_string_literal: true

require "json"
require_relative "tool_search_tool_regex"

# tool_search_tool_bm25 — picoclaw `pkg/tools/search_tool.go`
# (BM25SearchTool). Natural-language search over hidden tools (corpus
# "name description", BM25 k1=1.2 b=0.75); matches promoted + announced.
class ToolSearchToolBM25 < Brute::Tool
  description "Search available hidden tools on-demand using natural language query describing the action you need to perform. Returns JSON schemas of discovered tools."
  params({
    "type" => "object",
    "properties" => {
      "query" => { "type" => "string", "description" => "Search query" },
    },
    "required" => ["query"],
  })

  def initialize(manager:)
    @manager = manager
  end

  def name = "tool_search_tool_bm25"

  def execute(query: nil, **_args)
    if !query.is_a?(String) || query.strip.empty?
      return "Missing or invalid 'query' argument. Must be a non-empty string."
    end

    results = @manager.search_bm25(query, @manager.max_search_results)
    return "No tools found matching the query." if results.empty?

    Discovery.format(@manager, results)
  end
end
