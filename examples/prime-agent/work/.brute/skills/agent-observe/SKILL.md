---
name: agent-observe
description: Read-only observation of an agent's parent, siblings, and direct children. Use to inspect family status and bounded recent-message previews without mutating sessions.
---

# Agent Observe

SCAFFOLD — no-op port of prime-agent `packages/coding-agent/skills/agent-observe`.
The functions below exist but return a "not implemented" error payload; see
FEATURES.md (S10 + M7) for the fill-in contract.

Observe the current agent's nuclear family: parent, siblings, direct
children, and self. This skill is read-only: it can list family sessions,
inspect one session, and fetch bounded recent-message previews. It cannot
prompt, steer, clear, kill, rename, or otherwise mutate another session.
Read models live in Middleware::AgentObserve.

Call directly from IRuby:

    require "agent_observe"
    children = KernelAgent.list
    child = children.find(&:alive?)
    if child
      worker = AgentObserve.get_agent(child.name)
      recent = AgentObserve.recent_messages(child.name, limit: 6)
    end

## API

- `AgentObserve.list_agents` — returns `current` and `agents`. Each agent
  includes session id, optional name, runtime kind, computed `status`
  (`"tool"`, `"model"`, `"compacting"`, `"busy"`, `"user"`, `"idle"`),
  message counts, and a latest-message preview (truncated to 240 chars).
- `AgentObserve.get_agent(target)` — one session summary by id, name, or
  unambiguous suffix.
- `AgentObserve.recent_messages(target, limit: 8, max_chars: 800)` — bounded
  recent message previews: `limit` clamps 1-50, `max_chars` clamps 80-2000.
