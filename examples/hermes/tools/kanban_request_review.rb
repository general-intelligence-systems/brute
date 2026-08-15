# frozen_string_literal: true

require "json"

# kanban_request_review — hermes toolset: kanban
# Port of hermes-agent `tools/kanban_tools.py:2392` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_kanban_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KANBAN_REQUEST_REVIEW_SCHEMA
module HermesTools
  class KanbanRequestReview < Brute::Tool
    description "kanban_request_review (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "kanban_request_review"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "kanban_request_review")
    end
  end
end
