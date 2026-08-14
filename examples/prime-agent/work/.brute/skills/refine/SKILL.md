---
name: refine
description: Trigger continual harness refinement from IRuby. Use when you notice a repeated failure, reusable tactic, delegation role, or behavior policy that should be persisted as a harness entry. Returns immediately; refinement runs when the current turn ends.
---

# Refine

Refinement analyzes the conversation trajectory and applies small, evidence-backed
updates to the continual harness (prompts, memories, skills, subagent specs).
The implementation lives in the host; this skill is the kernel-side interface
to it. Call it directly from IRuby:

```ruby
refine.status
refine.run
refine.run("create a memory about always checking git status before committing")
refine.run("promote the error-handling pattern to a global skill", global_: true)
refine.run(rollback_id: "refine_20260814100528123")   # undo a bad refinement
```

## API

- `refine.status` — current refine state as a Hash: `pending` (whether a
  requested refine is already queued for this turn) and `request_path`.
- `refine.run(instructions = nil, global_: false, rollback_id: nil)` — schedule
  refinement. Returns immediately. Optional `instructions` focus the refinement
  on a specific observation. Set `global_: true` to target the global harness
  store (cross-session); omit for local (session-scoped) refinement. Pass
  `rollback_id` to undo a previous refinement.

## Rules

- Refinement never runs mid-cell. A scheduled refinement runs when the current
  turn ends; the harness applies changes and the system prompt refreshes on the
  next turn. Continue working normally after calling it.
- One request per turn is enough.
- Use refinement after observing a repeated failure, a reusable tactic, a
  repeated delegation role, or a behavior policy worth persisting. Do not
  rewrite the whole harness when a focused memory, skill, prompt note, or
  subagent spec is enough.
- Direct CRUD needs no refinement round-trip: `harness.create_memory(...)`,
  `harness.create_skill(...)`, `harness.create_prompt_note(...)`,
  `harness.overview()` and friends write the harness immediately from the
  kernel.
