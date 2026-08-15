# frozen_string_literal: true

require "json"

# Goal — prime-agent bundled skill `goal`. SCAFFOLD: no-op (FEATURES.md S8).
# Port of prime-agent `packages/coding-agent/skills/goal/src/goal/__init__.py`:
# manage the persistent thread goal from the kernel — a thin typed wrapper
# over the host bridge (Middleware::Goal owns all state).
# Loaded into IRuby via require "goal".
# Returns the scaffold error payload until filled in.
module Goal
  module_function

  # Current thread goal: {"goal", "remaining_tokens", "completion_budget_report"}.
  def get
    not_implemented("get")
  end

  # Start a new active thread goal. Fails while one is pending (active,
  # paused, budget-limited); a completed/errored goal is replaced. Only
  # create when the user or system instructions explicitly ask.
  def create(objective, token_budget: nil)
    not_implemented("create")
  end

  # Mark the existing thread goal achieved — only when it actually is.
  def complete
    not_implemented("complete")
  end

  def not_implemented(function)
    JSON.dump("error" => "not implemented", "skill" => "goal", "function" => function)
  end
end
