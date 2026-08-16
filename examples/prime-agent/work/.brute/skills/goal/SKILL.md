---
name: goal
description: Manage the persistent thread goal from IRuby. Use to read goal status and budget usage, to start a goal when the user explicitly asks for one, or to mark the active goal complete once its objective is fully achieved.
---

# Goal

The thread goal is a persistent objective the harness keeps re-prompting you
to pursue across turns until it is complete. Goal state (status, token
budget, usage accounting) lives in the host; this skill is the kernel-side
interface to it, preloaded into the kernel namespace. Call directly from
IRuby:

    goal.get
    goal.create("ship the release notes", token_budget: 200000)
    goal.complete

## API

- `goal.get` — current goal as a Hash: `goal` (or `nil` when no goal is
  set), `remaining_tokens`, and `completion_budget_report`. The `goal` Hash
  carries `objective`, `status`, `token_budget`, `tokens_used`,
  `time_used_seconds`, and timestamps.
- `goal.create(objective, token_budget: nil)` — start a new active goal.
  Raises while a goal is still pending (active, paused, or budget-limited);
  a completed or errored goal is replaced by the new one. Only create a goal
  when the user or system/developer instructions explicitly ask for a
  persistent long-running goal; do not infer goals from ordinary tasks. Set
  `token_budget` only when an explicit token budget is requested. Returns
  `{"scheduled" => true}`; the goal activates when the current turn ends.
- `goal.complete` — mark the existing thread goal achieved. Use only when
  the objective has actually been achieved and no required work remains —
  not because the budget is nearly exhausted or because you are stopping
  work. Pause, resume, and budget-limit transitions are controlled by the
  user and the host.

## Rules

- The goal persists across turns and compactions. Ending one turn does not
  reduce or redefine the objective; the host re-prompts you with the goal
  context after every turn while it is active.
- Before calling `goal.complete`, audit the current state against every
  requirement in the objective — do not rely on intent, partial progress, or
  a plausible final answer as proof of completion.
