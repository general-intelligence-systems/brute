# frozen_string_literal: true

require "json"

# browser_navigate — hermes toolset: browser
# Port of hermes-agent `tools/browser_tool.py:5302` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_browser_requirements
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: _BROWSER_SCHEMA_MAP['browser_navigate']
module HermesTools
  class BrowserNavigate < Brute::Tool
    description "browser_navigate (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "browser_navigate"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "browser_navigate")
    end
  end
end
