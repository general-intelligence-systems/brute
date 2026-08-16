# frozen_string_literal: true

# Linear — prime-agent bundled skill `linear` (FEATURES.md S12): read and
# write Linear issues, projects, cycles, comments, and more via Linear's
# official hosted MCP server (https://mcp.linear.app/mcp). The protocol
# client is the `mcp` gem; credentials come from the shared auth.json via
# PrimeAgent::Mcp (loaded into the kernel by the bootstrap). Tools are
# auto-discovered from the server — discover before you call:
#
#   require "linear"
#   Linear.list_tools.each { |t| puts "#{t["name"]} - #{t["description"]}" }
#   Linear.call_tool("list_issues", team: "Engineering")
#
# Raises PrimeAgent::Mcp::NotEnabled when the user isn't logged in (walk them
# through `ruby mcp_login.rb linear` — don't ask for environment variables).
module Linear
  INTEGRATION = PrimeAgent::Mcp::Integration.new(server: "linear")

  module_function

  def list_tools
    INTEGRATION.list_tools
  end

  def call_tool(name, **arguments)
    INTEGRATION.call_tool(name, **arguments)
  end
end
