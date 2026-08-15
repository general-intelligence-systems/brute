# frozen_string_literal: true

require "json"

# kanban_comment — hermes toolset: kanban
# Port of hermes-agent `tools/kanban_tools.py:2419` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_kanban_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KANBAN_COMMENT_SCHEMA
module HermesTools
  class KanbanComment < Brute::Tool
    description "kanban_comment (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "kanban_comment"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "kanban_comment")
    end
  end
end
