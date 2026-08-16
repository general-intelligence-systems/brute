# frozen_string_literal: true

require "json"
require_relative "fs_sandbox"

# message — picoclaw `pkg/tools/integration/message.go`, delivered to the
# outbox (outbound.jsonl). channel/chat_id default to the inbound turn's
# context (cli/direct here). Media attachments (tools.message.media_enabled)
# are workspace-validated, size-capped, and stored in the media store with
# forget_only cleanup; their refs go into the outbox record.
class Message < Brute::Tool
  description "Send a message to the user on a chat channel. Supports text-only, media-only, " \
              "or text with media attachments."
  params({
    "type" => "object",
    "properties" => {
      "content" => { "type" => "string", "description" => "Optional message text. When media is present, this text is used as the caption/body for the media message." },
      "channel" => { "type" => "string", "description" => "Optional: target channel (telegram, whatsapp, etc.)" },
      "chat_id" => { "type" => "string", "description" => "Optional: target chat/user ID" },
      "reply_to_message_id" => { "type" => "string", "description" => "Optional: reply target message ID for channels that support threaded replies" },
      "media" => { "type" => "array", "description" => "Optional local media attachments to send with the message. Requires tools.message.media_enabled.",
                   "items" => { "type" => "object", "properties" => {
                     "path" => { "type" => "string", "description" => "Path to the local file. Relative paths are resolved from workspace." },
                     "type" => { "type" => "string", "description" => "Optional media type hint: image, audio, video, or file." },
                     "filename" => { "type" => "string", "description" => "Optional display filename. Defaults to the basename of path." },
                   }, "required" => ["path"] } },
    },
    "required" => [],
  })

  def initialize(outbox:, workspace: Dir.pwd, restrict: true, media_enabled: false,
                 media_store: nil, max_media_size: 20 * 1024 * 1024, allow_paths: [])
    @outbox = outbox
    @workspace = workspace
    @restrict = restrict
    @media_enabled = media_enabled
    @media_store = media_store
    @max_media_size = max_media_size
    @allow_paths = allow_paths
  end

  def name = "message"

  def execute(content: nil, channel: nil, chat_id: nil, reply_to_message_id: nil, media: nil, **_args)
    content = content.to_s
    channel = channel.to_s.empty? ? "cli" : channel
    chat_id = chat_id.to_s.empty? ? "direct" : chat_id

    refs = []
    if media.is_a?(Array) && !media.empty?
      return "media attachments are not enabled (tools.message.media_enabled)" unless @media_enabled

      media.each do |item|
        item = item.to_h.transform_keys(&:to_sym)
        path = item[:path].to_s
        return "media path is required" if path.empty?

        abs = FsSandbox.validate_path(path, workspace: @workspace, restrict: @restrict, patterns: @allow_paths)
        return "media file not found: #{path}" unless File.file?(abs)
        return "media file exceeds the #{@max_media_size} byte limit: #{path}" if File.size(abs) > @max_media_size

        filename = item[:filename].to_s.empty? ? File.basename(abs) : item[:filename].to_s
        if @media_store
          refs << @media_store.store(abs, meta: { filename: filename, content_type: item[:type].to_s,
                                                  source: "tool:message:#{channel}:#{chat_id}",
                                                  cleanup_policy: "forget_only" },
                                     scope: "tool:message:#{channel}:#{chat_id}")
        else
          refs << abs
        end
      end
    end

    return "message requires content or media" if content.empty? && refs.empty?

    @outbox.append(channel: channel, chat_id: chat_id, content: content,
                   media: refs, reply_to_message_id: reply_to_message_id)
    "Message sent."
  rescue FsSandbox::Error => e
    e.message
  rescue StandardError => e
    warn("message crashed: #{e.class}: #{e.message}")
    e.message
  end
end
