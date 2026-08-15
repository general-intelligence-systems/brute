# frozen_string_literal: true

require "json"

# read_terminal — hermes toolset: desktop_ui
# Port of hermes-agent `tools/read_terminal_tool.py:79` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class ReadTerminal < Brute::Tool
    description "Read what's currently shown in the in-app terminal pane of the Hermes desktop GUI (the embedded shell beside this chat). Call with no arguments to get the visible screen plus the total line count (`total_lines`). To page through scrollback, pass `start_line` (0 = oldest line) and `count`; valid lines are [0, total_lines). Returns JSON: {total_lines, start, end, viewport_rows, cursor_row, text}."
    params({ "type" => "object", "properties" => { "start_line" => { "type" => "integer", "description" => "0-indexed first line (0 = oldest). Omit for the visible screen." }, "count" => { "type" => "integer", "description" => "Lines to read from start_line. Defaults to the visible row count." } } })
    def name = "read_terminal"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "read_terminal")
    end
  end
end
