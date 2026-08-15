# frozen_string_literal: true

require "json"

# TokenEstimator — picoclaw's pkg/tokenizer/estimator.go port.
# Shared by ContextBudget (proactive trim) and Compaction (summarize trigger).
module TokenEstimator
  MESSAGE_OVERHEAD = 12
  MEDIA_TOKENS_PER_ITEM = 256
  TOOL_OVERHEAD = 20

  module_function

  # EstimateMessageTokens: max(content chars, system parts chars + 20/part) +
  # reasoning + tool-call fields + 12, all x 2/5, +256 per media item.
  def message_tokens(msg)
    content_chars = msg.content.to_s.length

    # SystemParts (structured cache blocks) are an alternative representation.
    system_parts = msg.respond_to?(:system_parts) ? msg.system_parts.to_a : []
    parts_chars = 0
    unless system_parts.empty?
      system_parts.each { |part| parts_chars += part.to_s.length }
      parts_chars += system_parts.size * 20
    end

    chars = [content_chars, parts_chars].max
    chars += msg.respond_to?(:reasoning_content) ? msg.reasoning_content.to_s.length : 0

    msg.tool_calls.to_a.each do |tc|
      chars += tc.id.to_s.length
      chars += tc.respond_to?(:type) ? tc.type.to_s.length : 0
      chars += tc.name.to_s.length + tc.arguments.to_json.length
    end
    chars += msg.tool_call_id.to_s.length
    chars += MESSAGE_OVERHEAD

    media = msg.respond_to?(:media) ? msg.media.to_a : []
    (chars * 2 / 5) + media.size * MEDIA_TOKENS_PER_ITEM
  end

  # EstimateToolDefsTokens: (name + description + params JSON + 20) x 2/5.
  def tool_defs_tokens(defs)
    defs.to_a.sum do |d|
      function = d.is_a?(Hash) ? (d[:function] || d["function"] || d) : d
      name = function[:name] || function["name"].to_s
      description = function[:description] || function["description"].to_s
      parameters = function[:parameters] || function["parameters"]
      (name.to_s.length + description.to_s.length + (parameters ? parameters.to_json.length : 0) + TOOL_OVERHEAD)
    end * 2 / 5
  end

  def messages_tokens(messages)
    messages.to_a.sum { |m| message_tokens(m) }
  end
end
