# frozen_string_literal: true

require "json"

# open_preview — hermes toolset: desktop_ui
# Port of hermes-agent `tools/open_preview_tool.py:86` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class OpenPreview < Brute::Tool
    description "Open something in the preview pane beside the chat in the Hermes desktop app. Use this when the user asks to see a page, dev server, or file in the preview pane — e.g. \"open cnn.com in the preview pane\" or \"preview localhost:3000\". Accepts a web URL (a bare domain like www.cnn.com is fine), a localhost dev-server URL, or a file path (HTML renders live; other files show their contents). The pane opens for the current window only."
    params({ "type" => "object", "properties" => { "url" => { "type" => "string", "description" => "What to preview: a web URL (https://… or a bare domain), a localhost URL (localhost:3000), or a file path." }, "label" => { "type" => "string", "description" => "Optional tab label; defaults to the target's name." } }, "required" => ["url"] })
    def name = "open_preview"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "open_preview")
    end
  end
end
