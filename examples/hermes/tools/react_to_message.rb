# frozen_string_literal: true

require "json"

# react_to_message — hermes toolset: desktop_ui
# Port of hermes-agent `tools/react_to_message_tool.py:155` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_react_requirements
module HermesTools
  class ReactToMessage < Brute::Tool
    description "React to a message with a single emoji, the way you'd tapback in iMessage. Reach for it when a reaction is what a person would do: something funny gets a 😂, warmth gets a ❤️, a plan you're on board with gets a 👍 — then just carry on with whatever the message actually needs. If a reaction says it all, it can BE the reply (skip the redundant 'sounds good!' turn). Use it like a person would: occasionally, when felt — not on every message, and never as a status signal. NEVER narrate or explain a reaction ('I reacted with...', 'Reacting now') — the emoji appearing on the bubble is the whole point, and commentary kills it. Defaults to the user's most recent message. One reaction per message: a different emoji replaces yours, an empty string retracts it."
    params({ "type" => "object", "properties" => { "emoji" => { "type" => "string", "description" => "The emoji to react with (e.g. '❤️', '😂', '👍'). Pass an empty string to remove your reaction." }, "message_row_id" => { "type" => "integer", "description" => "Optional. The specific message to react to. Omit to react to the user's latest message, which is almost always what you want." }, "messages_back" => { "type" => "integer", "description" => "Optional. React to an EARLIER user message: 1 = the one before the latest, 2 = two before, and so on. For when something lands late — the joke you only got after answering." } }, "required" => ["emoji"] })
    def name = "react_to_message"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "react_to_message")
    end
  end
end
