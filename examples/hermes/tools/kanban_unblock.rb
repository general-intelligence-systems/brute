# frozen_string_literal: true

require "json"

# kanban_unblock — hermes toolset: kanban
# Port of hermes-agent `tools/kanban_tools.py:2464` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_kanban_orchestrator_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KANBAN_UNBLOCK_SCHEMA
module HermesTools
  class KanbanUnblock < Brute::Tool
    description "kanban_unblock (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "kanban_unblock"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "kanban_unblock")
    end
  end
end
