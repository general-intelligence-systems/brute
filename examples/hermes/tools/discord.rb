# frozen_string_literal: true

require "json"

# discord — hermes toolset: discord
# Port of hermes-agent `tools/discord_tool.py:1100` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_discord_tool_requirements
# hermes requires_env: DISCORD_BOT_TOKEN
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: _STATIC_CORE_SCHEMA
module HermesTools
  class Discord < Brute::Tool
    description "discord (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "discord"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "discord")
    end
  end
end
