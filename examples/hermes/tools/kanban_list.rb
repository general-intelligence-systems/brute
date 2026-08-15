# frozen_string_literal: true

require "json"

# kanban_list — hermes toolset: kanban
# Port of hermes-agent `tools/kanban_tools.py:2365` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_kanban_orchestrator_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KANBAN_LIST_SCHEMA
module HermesTools
  class KanbanList < Brute::Tool
    description "kanban_list (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "kanban_list"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "kanban_list")
    end
  end
end
