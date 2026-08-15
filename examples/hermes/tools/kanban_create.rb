# frozen_string_literal: true

require "json"

# kanban_create — hermes toolset: kanban
# Port of hermes-agent `tools/kanban_tools.py:2455` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_kanban_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KANBAN_CREATE_SCHEMA
module HermesTools
  class KanbanCreate < Brute::Tool
    description "kanban_create (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "kanban_create"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "kanban_create")
    end
  end
end
