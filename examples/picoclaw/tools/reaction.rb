# frozen_string_literal: true

require "json"

# reaction — picoclaw `pkg/tools/integration/reaction.go`. Registered
# unconditionally upstream, but this port's only channel (cli) is not
# ReactionCapable, so every call errors at execution — same observable
# behavior as upstream on a non-capable channel.
class Reaction < Brute::Tool
  description "Add a reaction to a message. Defaults to the current inbound message when message_id is omitted."
  params({
    "type" => "object",
    "properties" => {
      "message_id" => { "type" => "string", "description" => "Optional: target message ID; defaults to the current inbound message" },
      "channel" => { "type" => "string", "description" => "Optional: target channel (telegram, whatsapp, etc.)" },
      "chat_id" => { "type" => "string", "description" => "Optional: target chat/user ID" },
    },
    "required" => [],
  })

  def name = "reaction"

  def execute(**_args)
    "channel cli does not support reactions"
  end
end
