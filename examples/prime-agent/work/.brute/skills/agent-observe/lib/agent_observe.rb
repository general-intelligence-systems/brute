# frozen_string_literal: true

require "json"

# AgentObserve — prime-agent bundled skill `agent-observe`. SCAFFOLD: no-op
# (FEATURES.md S10). Port of prime-agent
# `packages/coding-agent/skills/agent-observe/src/agent_observe/__init__.py`:
# read-only observation of the agent family — thin typed wrappers over the
# host bridge (Middleware::AgentObserve owns the read model; never mutates).
# Loaded into IRuby via require "agent_observe".
# Returns the scaffold error payload until filled in.
module AgentObserve
  module_function

  # List active sessions visible to this agent: {"current", "agents"}.
  def list_agents
    not_implemented("list_agents")
  end

  # One session summary by id, name, or unambiguous suffix.
  def get_agent(target)
    not_implemented("get_agent")
  end

  # Bounded recent message previews from one session.
  # limit: 1-50 (default 8); max_chars: 80-2000 (default 800).
  def recent_messages(target, limit: 8, max_chars: 800)
    not_implemented("recent_messages")
  end

  def not_implemented(function)
    JSON.dump("error" => "not implemented", "skill" => "agent-observe", "function" => function)
  end
end
