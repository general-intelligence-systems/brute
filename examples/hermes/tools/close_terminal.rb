# frozen_string_literal: true

require "json"

# close_terminal — hermes toolset: desktop_ui
# Port of hermes-agent `tools/close_terminal_tool.py:56` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class CloseTerminal < Brute::Tool
    description "Close the read-only terminal tab for one of your background processes in the Hermes desktop GUI (the tabs mirroring terminal(background=true) runs). This does NOT kill the process — it only drops the tab/view; the output keeps buffering and the user can reopen it from the status stack. Use it to tidy up when a background process's live terminal is no longer worth showing. To actually stop the process, use process(action='kill') instead."
    params({ "type" => "object", "properties" => { "process_id" => { "type" => "string", "description" => "The background process's session id (from terminal(background=true) output or process(action='list')) whose tab should be closed." } }, "required" => ["process_id"] })
    def name = "close_terminal"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "close_terminal")
    end
  end
end
