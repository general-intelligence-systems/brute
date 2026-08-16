# frozen_string_literal: true

# Notion — prime-agent bundled skill `notion` (FEATURES.md S13): search
# Notion and read/create/update pages and databases via Notion's official
# hosted MCP server (https://mcp.notion.com/mcp). The protocol client is the
# `mcp` gem; credentials come from the shared auth.json via PrimeAgent::Mcp
# (loaded into the kernel by the bootstrap). Tools are auto-discovered from
# the server — discover before you call. Notion's tool names contain hyphens
# (e.g. `notion-search`), so call them via call_tool:
#
#   require "notion"
#   Notion.list_tools.each { |t| puts "#{t["name"]} - #{t["description"]}" }
#   Notion.call_tool("notion-search", query: "roadmap")
#
# Raises PrimeAgent::Mcp::NotEnabled when the user isn't logged in (walk them
# through `ruby mcp_login.rb notion` — don't ask for environment variables).
module Notion
  INTEGRATION = PrimeAgent::Mcp::Integration.new(server: "notion")

  module_function

  def list_tools
    INTEGRATION.list_tools
  end

  def call_tool(name, **arguments)
    INTEGRATION.call_tool(name, **arguments)
  end
end
