# frozen_string_literal: true

require "json"

# kanban_show — hermes toolset: kanban
# Port of hermes-agent `tools/kanban_tools.py:2356` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_kanban_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KANBAN_SHOW_SCHEMA
module HermesTools
  class KanbanShow < Brute::Tool
    description "kanban_show (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "kanban_show"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "kanban_show")
    end
  end
end
