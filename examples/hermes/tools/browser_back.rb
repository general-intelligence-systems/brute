# frozen_string_literal: true

require "json"

# browser_back — hermes toolset: browser
# Port of hermes-agent `tools/browser_tool.py:5343` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_browser_requirements
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: _BROWSER_SCHEMA_MAP['browser_back']
module HermesTools
  class BrowserBack < Brute::Tool
    description "browser_back (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "browser_back"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "browser_back")
    end
  end
end
