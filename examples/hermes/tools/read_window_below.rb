# frozen_string_literal: true

require "json"

# read_window_below — hermes toolset: desktop_ui
# Port of hermes-agent `tools/read_window_tool.py:65` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class ReadWindowBelow < Brute::Tool
    description "Identify the application window directly underneath (behind) the Hermes desktop window — what the user is working in behind this app. Returns JSON: {window: {app, title, bounds{x,y,width,height}, id}, frontmost: {app, title}, platform}. `title` may be empty when the OS withholds window titles (e.g. macOS without the Screen Recording permission — never prompted for, noted in `note`). Other Hermes windows are skipped: the nearest non-Hermes window is reported. Returns {error, platform} instead where the OS cannot enumerate windows at all (e.g. a Wayland session); `error` says what would fix it, so relay it rather than retrying. Metadata only; this never captures pixels or content of other windows."
    params({ "type" => "object", "properties" => {} })
    def name = "read_window_below"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "read_window_below")
    end
  end
end
