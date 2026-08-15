# frozen_string_literal: true

require "json"

# focus_pane — hermes toolset: desktop_ui
# Port of hermes-agent `tools/focus_pane_tool.py:58` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: FOCUS_PANE_SCHEMA
module HermesTools
  class FocusPane < Brute::Tool
    description "focus_pane (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "focus_pane"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "focus_pane")
    end
  end
end
