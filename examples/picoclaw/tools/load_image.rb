# frozen_string_literal: true

require "json"

# load_image — picoclaw `pkg/tools/fs/load_image.go` (LoadImageTool).
# Gate: tools.load_image.enabled (default true); size <= max_media_size (20MB),
# MIME must be image/*. Returns a media:// ref that the media middleware
# inlines as base64 on the next LLM call.
# Scaffold: no-op handler, returns a JSON error string.
class LoadImage < Brute::Tool
  description "Load a local image file so you can analyze its contents with vision. Supported " \
              "formats: JPEG, PNG, GIF, WebP, BMP. After calling this tool, describe or analyze " \
              "the image in your next response."
  params({
    "type" => "object",
    "properties" => {
      "path" => { "type" => "string", "description" => "Path to the local image file. Relative paths are resolved from workspace." },
    },
    "required" => ["path"],
  })

  def name = "load_image"

  def execute(**_args)
    JSON.dump("error" => "not implemented", "tool" => "load_image")
  end
end
