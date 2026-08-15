# frozen_string_literal: true

require "json"

# browser_exec — hermes toolset: browser-use
# Port of hermes-agent `tools/browser_use_cli.py:704` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: is_browser_use_cli_mode
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: BROWSER_EXEC_SCHEMA
module HermesTools
  class BrowserExec < Brute::Tool
    description "browser_exec (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "browser_exec"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "browser_exec")
    end
  end
end
