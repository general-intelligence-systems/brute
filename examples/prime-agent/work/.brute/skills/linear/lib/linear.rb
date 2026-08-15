# frozen_string_literal: true

require "json"

# Linear — prime-agent bundled skill `linear`. SCAFFOLD: no-op
# (FEATURES.md S12). Port of prime-agent
# `packages/coding-agent/skills/linear/src/linear/__init__.py` (an
# McpIntegration subclass, server https://mcp.linear.app/mcp): MCP tools are
# auto-discovered from the server at runtime — thin wrappers over the host
# bridge (Middleware::McpManager owns OAuth + credentials).
# Loaded into IRuby via require "linear".
# Returns the scaffold error payload until filled in.
module Linear
  module_function

  SERVER = "linear"
  URL = "https://mcp.linear.app/mcp"

  # Discover the server's tools (names + JSON schemas).
  # Fill-in: raise a NotEnabled-style error telling the model to ask the
  # user to log in when no credential exists.
  def list_tools
    not_implemented("list_tools")
  end

  # Call one discovered tool by name with keyword arguments.
  # Fill-in: one fresh HTTP session per call with the OAuth bearer token;
  # refresh via the host bridge on expiry (30s skew); raise on isError.
  def call_tool(name, **arguments)
    not_implemented("call_tool")
  end

  def not_implemented(function)
    JSON.dump("error" => "not implemented", "skill" => "linear", "function" => function)
  end
end
