# frozen_string_literal: true

require "json"

# browser_vision — hermes toolset: browser
# Port of hermes-agent `tools/browser_tool.py:5368` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_browser_vision_requirements
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: _BROWSER_SCHEMA_MAP['browser_vision']
module HermesTools
  class BrowserVision < Brute::Tool
    description "browser_vision (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "browser_vision"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "browser_vision")
    end
  end
end
