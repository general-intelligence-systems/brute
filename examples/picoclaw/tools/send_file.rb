# frozen_string_literal: true

require "json"
require_relative "fs_sandbox"

# send_file — picoclaw `pkg/tools/fs/send_file.go`, delivered to the outbox.
# Workspace/allow-path validated, size-capped (agents.defaults.max_media_size,
# 20MB), stored in the media store; the ref rides the outbox record.
class SendFile < Brute::Tool
  description "Send a local file (image, document, etc.) to the user on the current chat channel."
  params({
    "type" => "object",
    "properties" => {
      "path" => { "type" => "string", "description" => "Path to the local file. Relative paths are resolved from workspace." },
      "filename" => { "type" => "string", "description" => "Optional display filename. Defaults to the basename of path." },
    },
    "required" => ["path"],
  })

  def initialize(outbox:, workspace: Dir.pwd, restrict: true, media_store: nil,
                 max_media_size: 20 * 1024 * 1024, allow_paths: [])
    @outbox = outbox
    @workspace = workspace
    @restrict = restrict
    @media_store = media_store
    @max_media_size = max_media_size
    @allow_paths = allow_paths
  end

  def name = "send_file"

  def execute(path: nil, filename: nil, **_args)
    return "path is required" unless path.is_a?(String) && !path.empty?

    abs = FsSandbox.validate_path(path, workspace: @workspace, restrict: @restrict, patterns: @allow_paths)
    return "file not found: #{path}" unless File.file?(abs)
    return "file exceeds the #{@max_media_size} byte limit: #{path}" if File.size(abs) > @max_media_size

    filename = filename.to_s.empty? ? File.basename(abs) : filename.to_s
    ref =
      if @media_store
        @media_store.store(abs, meta: { filename: filename, cleanup_policy: "delete_on_cleanup",
                                        source: "tool:send_file" },
                               scope: "tool:send_file:cli:direct")
      else
        abs
      end

    @outbox.append(channel: "cli", chat_id: "direct", content: filename, media: [ref])
    "File sent: #{filename}"
  rescue FsSandbox::Error => e
    e.message
  rescue StandardError => e
    warn("send_file crashed: #{e.class}: #{e.message}")
    e.message
  end
end
