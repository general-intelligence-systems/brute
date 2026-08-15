---
name: agent-message
description: Message an agent's parent, siblings, or direct children. Use the family roster to discover reachable agents and send direct text without spoofing sender identity.
---

# Agent Message

SCAFFOLD — no-op port of prime-agent `packages/coding-agent/skills/agent-message`.
The functions below exist but return a "not implemented" error payload; see
FEATURES.md (S9 + M6) for the fill-in contract.

Send direct messages within the current agent's nuclear family: parent,
siblings, and direct children only. Roots are siblings. The host derives
your sender identity from the current session; do not try to include a
`from` field. Routing and limits live in Middleware::AgentMessages.

Call directly from IRuby:

    require "agent_message"
    children = KernelAgent.list
    child = children.find(&:alive?)
    if child
      receipt = AgentMessage.send(
        "Please inspect the latest result.",
        receiver_role: "child",
        receiver_name: child.name,
      )
      # Keep the child until this follow-up finishes so its result remains observable.
    end

## API

- `AgentMessage.list_agents` — returns `current` (`name`, `id`, `depth`)
  and family-scoped `entries` (`relationship`, `name`, `id`, `depth`,
  `status`).
- `AgentMessage.send(message, receiver_role:, receiver_name: nil)` — one
  direct role-addressed message. `receiver_role` is `"parent"`, `"sibling"`,
  or `"child"`; `receiver_name` is required for sibling/child and must be
  omitted for parent.
- `AgentMessage.send("all", broadcast)` — broadcast to every roster entry;
  returns `{"receipts" => [...]}` with per-target receipts.
- Receipts carry `deliveryStatus`: `"delivered"` when it reached an idle
  target's context, `"queued"` when accepted for later delivery. Delivery is
  always steer; messages cap at 16_384 chars, 20 pending per session, and a
  3-per-second rate limit per sender->target pair.
