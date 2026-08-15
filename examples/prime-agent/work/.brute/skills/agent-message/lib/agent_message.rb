# frozen_string_literal: true

require "json"

# AgentMessage — prime-agent bundled skill `agent-message`. SCAFFOLD: no-op
# (FEATURES.md S9). Port of prime-agent
# `packages/coding-agent/skills/agent-message/src/agent_message/__init__.py`:
# session-to-session messaging within the agent family — thin typed wrappers
# over the host bridge (Middleware::AgentMessages owns routing, sender
# identity, limits, and receipts).
# Loaded into IRuby via require "agent_message".
# Returns the scaffold error payload until filled in.
module AgentMessage
  module_function

  # List this agent's parent, siblings, and children, including inactive family.
  def list_agents
    not_implemented("list_agents")
  end

  # Send one direct role-addressed message, or broadcast:
  #   AgentMessage.send("hi", receiver_role: "child", receiver_name: "api-reviewer")
  #   AgentMessage.send("all", "broadcast to the whole family")
  # receiver_role is "parent" | "sibling" | "child"; receiver_name is
  # required for sibling/child, omitted for parent. Returns a receipt Hash
  # ({"deliveryStatus" => "delivered" | "queued"}) or {"receipts" => [...]}.
  def send(message, broadcast_message = nil, receiver_role: nil, receiver_name: nil)
    not_implemented("send")
  end

  def not_implemented(function)
    JSON.dump("error" => "not implemented", "skill" => "agent-message", "function" => function)
  end
end
