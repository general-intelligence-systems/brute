---
name: goal
description: Manage the persistent thread goal from IRuby. Use to read goal status and budget usage, to start a goal when the user explicitly asks for one, or to mark the active goal complete once its objective is fully achieved.
---

# Goal

SCAFFOLD — no-op port of prime-agent `packages/coding-agent/skills/goal`.
The functions below exist but return a "not implemented" error payload; see
FEATURES.md (S8 + M2) for the fill-in contract.

The thread goal is a persistent objective the harness keeps re-prompting you
to pursue across turns until it is complete. Goal state (status, token
budget, usage accounting) lives in the host (Middleware::Goal); this skill
is the kernel-side interface to it. Call directly from IRuby:

    require "goal"
    Goal.get
    Goal.create("ship the release notes", token_budget: 200000)
    Goal.complete

## API

- `Goal.get` — current goal as a Hash: `goal` (or `nil` when no goal is
  set), `remaining_tokens`, and `completion_budget_report`. The `goal` Hash
  carries `objective`, `status`, `token_budget`, `tokens_used`,
  `time_used_seconds`, and timestamps.
- `Goal.create(objective, token_budget: nil)` — start a new active goal.
  Fails while a goal is still pending (active, paused, or budget-limited); a
  completed or errored goal is replaced by the new one. Only create a goal
  when the user or system/developer instructions explicitly ask for a
  persistent long-running goal; do not infer goals from ordinary tasks. Set
  `token_budget` only when an explicit token budget is requested.
- `Goal.complete` — mark the existing thread goal achieved. Use only when
  the objective has actually been achieved and no required work remains —
  not because the budget is nearly exhausted or because you are stopping
  work. Pause, resume, and budget-limit transitions are controlled by the
  user and the host.
