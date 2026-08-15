# frozen_string_literal: true

require "json"

# read_preview — hermes toolset: desktop_ui
# Port of hermes-agent `tools/read_preview_tool.py:84` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class ReadPreview < Brute::Tool
    description "Read what's currently shown in the in-app browser / preview pane of the Hermes desktop GUI (the pane open_preview opens beside this chat). Call with no arguments for the first window of the active tab's content. Returns JSON {kind, url, title, text, start, end, total_chars, note?}: a URL (Browser) tab's text is the rendered page's visible text — page through longer pages with `start`/`count` (character offsets, capped per read); a file tab answers identity only (read the file with read_file); an artifact tab points back at the conversation. Use after open_preview, or whenever the user refers to what's on screen in the browser ('what does this page say?')."
    params({ "type" => "object", "properties" => { "start" => { "type" => "integer", "description" => "0-indexed character offset into the page text. Omit for the start." }, "count" => { "type" => "integer", "description" => "Characters to return from start. Defaults to (and is capped at) the per-read maximum." } } })
    def name = "read_preview"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "read_preview")
    end
  end
end
