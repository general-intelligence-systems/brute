# frozen_string_literal: true

require "json"
require_relative "fs_sandbox"

# load_image — picoclaw `pkg/tools/fs/load_image.go`. Validates (workspace /
# allow-read paths, <= max_media_size, image/* by magic bytes), stores the
# file in the media store, and returns the media:// ref in the result text —
# the Media middleware rewrites it to an [image:/path] tag before the next
# LLM call. (Base64 vision inlining is blocked on brute's message transport;
# the path tag carries the reference.)
class LoadImage < Brute::Tool
  MAGIC = {
    "\x89PNG\r\n\x1A\n".b => "image/png",
    "\xFF\xD8\xFF".b => "image/jpeg",
    "GIF8".b => "image/gif",
    "BM".b => "image/bmp",
    "RIFF" => "image/webp", # refined below (WEBP at offset 8)
  }.freeze

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

  def initialize(workspace: Dir.pwd, restrict: true, media_store: nil,
                 max_media_size: 20 * 1024 * 1024, allow_paths: [])
    @workspace = workspace
    @restrict = restrict
    @media_store = media_store
    @max_media_size = max_media_size
    @allow_paths = allow_paths
  end

  def name = "load_image"

  def execute(path: nil, **_args)
    return "path is required" unless path.is_a?(String) && !path.empty?

    abs = FsSandbox.validate_path(path, workspace: @workspace, restrict: @restrict, patterns: @allow_paths)
    return "file not found: #{path}" unless File.file?(abs)
    return "file exceeds the #{@max_media_size} byte limit: #{path}" if File.size(abs) > @max_media_size

    mime = detect_mime(abs)
    return "file is not a supported image (JPEG, PNG, GIF, WebP, BMP): #{path}" if mime.nil?

    ref =
      if @media_store
        @media_store.store(abs, meta: { filename: File.basename(abs), content_type: mime,
                                        cleanup_policy: "delete_on_cleanup", source: "tool:load_image" },
                               scope: "tool:load_image:cli:direct")
      else
        abs
      end

    "Image loaded: #{ref}\nDescribe or analyze the image in your next response."
  rescue FsSandbox::Error => e
    e.message
  rescue StandardError => e
    warn("load_image crashed: #{e.class}: #{e.message}")
    e.message
  end

  private

  def detect_mime(path)
    head = File.binread(path, 12)
    MAGIC.each do |magic, mime|
      next unless head.start_with?(magic)
      next if magic == "RIFF" && head[8, 4] != "WEBP"

      return mime
    end
    nil
  end
end
