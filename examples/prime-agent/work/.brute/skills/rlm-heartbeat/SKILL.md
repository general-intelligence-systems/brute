---
name: rlm-heartbeat
description: Manage agent-owned recurring instructions from IRuby. Use when the user asks the agent to start, create, schedule, or manage a heartbeat, unless they explicitly request the user's heartbeat.
---

# RLM Heartbeat

Agent-owned heartbeats are recurring instructions managed programmatically —
several may run at once. They are distinct from the user-owned heartbeat
(`BRUTE_HEARTBEAT`); this skill cannot replace or clear it. The job store is
a JSON file shared with the host, so these calls write it directly; the
host's scheduler claims due jobs and delivers each one as a fresh agent run
whose task is the heartbeat instruction. Call directly from IRuby:

    first = rlm_heartbeat.create("check whether the test run finished", interval: "5m", label: "tests")
    rlm_heartbeat.list
    rlm_heartbeat.update(first["id"], status: "pause")
    rlm_heartbeat.delete(first["id"])

## API

- `rlm_heartbeat.list(include_inactive: false)` — list internal heartbeats.
- `rlm_heartbeat.create(instruction, interval: nil, label: nil,
  delivery_mode: nil)` — create one. `interval` accepts "5m"/"30s"/"1h"
  style text or a cron expression (default "every 5m", minimum 10 seconds).
  `delivery_mode` ("steer"/"follow_up") is stored as metadata: in this port
  every delivery is effectively follow_up — a due heartbeat fires as its own
  run between runs, never mid-turn.
- `rlm_heartbeat.update(id, instruction: nil, interval: nil, label: nil,
  status: nil, delivery_mode: nil)` — `status` is "pause" or "resume".
- `rlm_heartbeat.delete(id)` — cancel one.

Each heartbeat Hash carries `id`, `status`, `label`, `delivery_mode`,
`instruction`, `schedule`, `created_at`, `updated_at`, `next_run_at`,
`last_run_at`, `last_error`, `run_count`.

## Rules

- Missed ticks coalesce: if runs don't happen for several intervals, the
  instruction fires exactly once when the scheduler next claims it — you
  will not see a backlog.
- Heartbeats fire between runs, not mid-cell and not mid-turn. Write results
  to files (or the harness) so later runs can fan them in.
