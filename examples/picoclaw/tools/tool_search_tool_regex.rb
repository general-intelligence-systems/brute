# frozen_string_literal: true

require "json"

# tool_search_tool_regex — picoclaw `pkg/tools/search_tool.go`
# (RegexSearchTool). Searches HIDDEN (deferred MCP) tools by case-insensitive
# regex over name+description; matches are promoted (callable as native tools
# for `ttl` turns) and announced with the unlock message.
class ToolSearchToolRegex < Brute::Tool
  MAX_PATTERN_LENGTH = 200

  description "Search available hidden tools on-demand using a regex pattern. Returns JSON schemas of discovered tools."
  params({
    "type" => "object",
    "properties" => {
      "pattern" => { "type" => "string", "description" => "Regex pattern to match tool name or description" },
    },
    "required" => ["pattern"],
  })

  def initialize(manager:)
    @manager = manager
  end

  def name = "tool_search_tool_regex"

  def execute(pattern: nil, **_args)
    if !pattern.is_a?(String) || pattern.strip.empty?
      return "Missing or invalid 'pattern' argument. Must be a non-empty string."
    end
    if pattern.length > MAX_PATTERN_LENGTH
      return "Pattern too long: max #{MAX_PATTERN_LENGTH} characters allowed"
    end

    begin
      results = @manager.search_regex(pattern, @manager.max_search_results)
    rescue RegexpError => e
      return "Invalid regex pattern syntax: #{e.message}. Please fix your regex and try again."
    end

    Discovery.format(@manager, results)
  end
end

# Shared discovery response (formatDiscoveryResponse port).
module Discovery
  def self.format(manager, results)
    return "No tools found matching the query." if results.empty?

    manager.promote!(results.map { |r| r[:name] })
    json = JSON.generate(results.map { |r| { "name" => r[:name], "description" => r[:description] } })
    "Found #{results.size} tools:\n#{json}\n\n" \
      "SUCCESS: These tools have been temporarily UNLOCKED as native tools! " \
      "In your next response, you can call them directly just like any normal tool"
  end
end
