# frozen_string_literal: true

require "json"

# kanban_attach_url — hermes toolset: kanban
# Port of hermes-agent `tools/kanban_tools.py:2437` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_kanban_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KANBAN_ATTACH_URL_SCHEMA
module HermesTools
  class KanbanAttachUrl < Brute::Tool
    description "kanban_attach_url (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "kanban_attach_url"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "kanban_attach_url")
    end
  end
end
