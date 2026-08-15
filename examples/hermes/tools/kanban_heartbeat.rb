# frozen_string_literal: true

require "json"

# kanban_heartbeat — hermes toolset: kanban
# Port of hermes-agent `tools/kanban_tools.py:2410` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_kanban_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KANBAN_HEARTBEAT_SCHEMA
module HermesTools
  class KanbanHeartbeat < Brute::Tool
    description "kanban_heartbeat (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "kanban_heartbeat"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "kanban_heartbeat")
    end
  end
end
