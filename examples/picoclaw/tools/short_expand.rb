# frozen_string_literal: true

require "json"

# short_expand — picoclaw's pkg/seahorse/tool_expand.go. Fetch full message
# content by ID (from short_grep results); tool_result content is omitted.
# Registered only when agents.defaults.context_manager == "seahorse".
class ShortExpand < Brute::Tool
  description <<~DESC.chomp
    Get full message content by ID.

    Use when short_grep returns messages and you need complete content (not just snippet).

    Parameters:
    - message_ids (required): Array of message ID strings (from short_grep results)

    Returns message with:
    - content: Full text content
    - parts: Structured content
      - text: Full text
      - tool_use: name, arguments, toolCallId
      - tool_result: toolCallId only (content omitted - re-run tool if needed)
      - media: mediaUri (file path), mimeType

    Notes:
    - tool_result content is not returned (can be large). Re-run the tool if you need the result.
    - Media files are stored on disk at mediaUri path, use bash to access.

    Example:
      {"message_ids": ["10", "25"]}
  DESC
  params({
    "type" => "object",
    "properties" => {
      "message_ids" => { "type" => "array", "items" => { "type" => "string" },
                         "description" => "Message IDs to expand (from short_grep results, e.g., [\"10\", \"25\"])" },
    },
    "required" => ["message_ids"],
  })

  def initialize(retrieval:)
    @retrieval = retrieval
  end

  def name = "short_expand"

  def execute(message_ids: nil, **_args)
    return "message_ids is required" unless message_ids.is_a?(Array) && !message_ids.empty?

    ids = message_ids.map { |id| Integer(id.to_s.strip, exception: false) }.compact
    return "message_ids must be numeric strings" if ids.empty?

    JSON.pretty_generate(@retrieval.expand(ids))
  rescue StandardError => e
    e.message
  end
end
