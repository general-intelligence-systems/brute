# frozen_string_literal: true

require "json"

# discord_admin — hermes toolset: discord_admin
# Port of hermes-agent `tools/discord_tool.py:1109` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_discord_tool_requirements
# hermes requires_env: DISCORD_BOT_TOKEN
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: _STATIC_ADMIN_SCHEMA
module HermesTools
  class DiscordAdmin < Brute::Tool
    description "discord_admin (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "discord_admin"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "discord_admin")
    end
  end
end
