# frozen_string_literal: true

require "json"

# setup_mcp — hermes toolset: desktop_ui
# Port of hermes-agent `tools/setup_mcp_tool.py:123` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class SetupMcp < Brute::Tool
    description "Propose an MCP server to the user as an inline consent card in the Hermes desktop chat. The card lets them install a catalog entry, re-enable a disabled server, or run an OAuth login — right there, without opening the Capabilities tab — and blocks until they act or decline. Use when the user asks to add/set up an MCP (e.g. \"add the linear mcp\"), or when a task clearly needs one that is missing or unauthorized. Never call it twice for the same server after a decline. Returns JSON {status: installed|enabled|authorized|declined|unanswered|error, server, detail?, tools?}. On declined/unanswered, continue without the server. Catalog names: run `hermes mcp catalog` in the terminal to list them."
    params({ "type" => "object", "properties" => { "server" => { "type" => "string", "description" => "The server's catalog name (for install) or its name in mcp_servers config (for enable/authorize)." }, "action" => { "type" => "string", "enum" => ["install", "enable", "authorize"], "description" => "install: add a catalog entry (prompts for any required keys). enable: re-enable a disabled configured server. authorize: run the OAuth browser flow for a configured server. Defaults to install." }, "reason" => { "type" => "string", "description" => "One short sentence shown on the card: why this server helps right now (e.g. \"To read the JIRA ticket you linked\")." } }, "required" => ["server"] })
    def name = "setup_mcp"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "setup_mcp")
    end
  end
end
