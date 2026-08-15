# Hermes → brute — Middleware Definitions (the loop/turn strategy)

Canonical definition of every middleware in the port, what it wraps, what it owns, and the
ordering rules that make the stack behave like hermes' `run_conversation`. Companion to
FEATURES.md (what we port) — this document is how.

## 0. Placement rules (read first)

brute runs `env` through a Rack-style stack toward a terminal proc. **Four** positions
exist, and choosing the right one is 90% of the design:

| Position | Wraps | Runs | Lives there |
|---|---|---|---|
| **Per-turn** (outside `Loop::ToolResult`) | the whole turn | once before & after | persistence, prompt, stores, nudges |
| **Per-iteration** (inside the loop) | one LLM call | before & after every call | interrupt, steering, budget, compaction, dispatch |
| **After-turn** (inside SessionStore, outside Loop) | the completed turn | once the final answer exists | background review fork |
| **Per-tool-call** (a `Brute::Turn::ToolPipeline` around each tool execution) | one tool run | before & after every tool execution | coercion, guards, approval, caps, audit — see §4 |

The fourth position is not optional garnish — it is *the* reason the middleware pattern
exists: cross-cutting per-call policy (validation, safety, approval, caps, auditing) as
composable layers around execution, instead of conditionals baked into a dispatcher.
Hermes independently reinvented this exact idea as its plugin `tool_request` /
`tool_execution` contract (`docs/middleware/README.md`); brute ships it natively as
`Brute::Turn::ToolPipeline`, where a tool call flows through middleware as
`env = { name:, arguments:, result:, events:, metadata: }` toward the handler proc.

Two hermes invariants constrain everything (FEATURES.md §0):

1. **Byte-stable prompt** — the system prompt is built/restored once per session, never
   mid-turn. Only `Compaction` may rewrite history.
2. **Role alternation** — nothing injects a user message mid-loop. Steering piggybacks on
   the last `:tool` message; proactive events (delegation/cron/process completions) enter as
   *new turns* drained by the driver (`main.rb`), never spliced in.

Hermes' "agent-loop intercepted tools" (`_AGENT_LOOP_TOOLS`: todo, memory, session_search,
delegate_task) map to brute tools whose handlers **close over `env` state installed by a
middleware**. So several middleware below both manage state *and* provide a tool.

---

## 1. The canonical stack (outer → inner)

```ruby
Brute.agent
  # ── per-turn ────────────────────────────────────────────────
  .use(Hermes::Middleware::Estop)                       # global pause sentinel
  .use(Hermes::Middleware::SessionStore,  path: ...)    # load history / persist markers
  .use(Hermes::Middleware::Memory,        dir: ...)     # memory.md/user.md stores + tool
  .use(Hermes::Middleware::Skills,        dirs: [...])  # index + 3 skill tools
  .use(Hermes::Middleware::Todo)                        # store + tool + compaction re-inject
  .use(Hermes::Middleware::PromptTiers,   soul:, context_files:)  # byte-stable prompt
  .use(Hermes::Middleware::Clarify,       handler: method(:ask_user))  # clarify tool
  .use(Hermes::Middleware::Delegation,    queue: COMPLETION_QUEUE)     # delegate_task tool
  .use(Hermes::Middleware::ProcessRegistry, queue: COMPLETION_QUEUE)   # process tool + bg
  .use(Hermes::Middleware::CronSchedule,  store: ...)   # cronjob tool (ticker is driver-side)
  .use(Hermes::Middleware::Nudge,         memory_interval: 10, skill_interval: 10,
                                        state_path: ...)      # durable counters (timer model)
  # ── the loop ────────────────────────────────────────────────
  .use(Brute::Middleware::Loop::ToolResult)
  # ── per-iteration ───────────────────────────────────────────
  .use(Hermes::Middleware::Interrupt)                   # flag → should_exit
  .use(Hermes::Middleware::Steering)                    # drain steer/redirect onto last :tool
  .use(Hermes::Middleware::IterationBudget, max_iterations: 90, grace: true)
  .use(Hermes::Middleware::Compaction,    compactor: COMPACTOR, threshold: 0.50)
  .use(Hermes::Middleware::ToolDispatch,  tools: TOOLS) # repair/intercept/parallel; wraps every
                                                        # tool in a Turn::ToolPipeline (see §4)
  .use(Hermes::Middleware::ErrorRecovery, fallback_model: nil, compactor: COMPACTOR)
  .use(Hermes::Middleware::TokenUsage)                  # record usage into env
  .run(proc { |env| /* LLM call via chosen transport */ })
```

After-phases unwind in reverse: the LLM call returns → `TokenUsage` records →
`ErrorRecovery` retries on classified failure → `ToolDispatch` executes tool calls →
`Compaction`/`IterationBudget`/`Steering`/`Interrupt` observe → loop condition re-checks.

---

## 2. Per-turn middleware

### 2.1 `Hermes::Middleware::Estop`
- **Ports:** `agent/estop.py`. Global pause sentinel (file-based, like `hermes pause`).
- **Before:** if the sentinel exists, halt the turn immediately (return env unchanged with a
  status event). Cron driver checks the same sentinel before dispatching.
- **Config:** `estop.path` (default `<work>/.estop`).
- **Tests:** sentinel present → no LLM call; absent → pass-through.

### 2.2 `Hermes::Middleware::SessionStore`
- **Ports:** `hermes_state.py` append-only flush + `run_agent.py:2000` marker logic.
  **SQLite via `extralite`** (github.com/digital-fabric/extralite) — decision locked.
- **Before:** load session messages into `env[:messages]`; stamp each with a persisted
  marker (an ivar / id-set, the Ruby `_DB_PERSISTED_MARKER`). Restore nudge counters (see 2.6).
- **After:** append only *unstamped* messages to the JSONL/SQLite store, in one batch;
  never persist messages flagged ephemeral (error-recovery scaffolding, review forks).
  Persist the system-prompt snapshot on first build (hand-in-hand with PromptTiers, 2.7).
- **Owns:** `env[:session_id]`, `env[:session_store]`. Later: FTS5 index → powers the
  `session_search` tool (scaffold exists).
- **Tests:** resume → counters hydrated; double-flush writes nothing twice; ephemeral-flagged
  messages never land on disk; crash before first LLM call still persisted the user message.

### 2.3 `Hermes::Middleware::Memory`
- **Ports:** `tools/memory_tool.py`, `agent/memory_manager.py` (file-backed subset).
- **Before:** load `memory.md` + `user.md` into `env[:memory]`; expose them to PromptTiers'
  volatile tier; install the `memory` tool (target `memory|user` ×
  `add|replace|remove|batch`) closing over the stores.
- **After:** flush store writes to disk (atomic tmp+rename).
- **Owns:** `env[:memory_store]`, `env[:user_store]`.
- **Tests:** each verb round-trips; batch is atomic; files render verbatim into the volatile
  tier; store survives a turn that raises.

### 2.4 `Hermes::Middleware::Skills`
- **Ports:** `tools/skills_tool.py`, `tools/skill_manager_tool.py`, `tools/skill_usage.py`.
- **Before:** scan skill dirs → `env[:skills]` (name, ≤60-char description, path) for the
  volatile tier's `<available_skills>` block; install `skills_list`, `skill_view`,
  `skill_manage` tools; enforce the write-protection matrix (bundled/hub/pinned/user-owned
  refused to autonomous writers; only `created_by: agent` writable by review forks).
- **Owns:** `env[:skills]`, `env[:skill_usage]` (telemetry sidecar: use_count, view_count,
  patch_count, last_activity_at, state, pinned).
- **Tests:** index renders; `skill_view` loads a SKILL.md; protection refuses a pinned delete;
  usage sidecar increments on view/manage.

### 2.5 `Hermes::Middleware::Todo`
- **Ports:** `tools/todo_tool.py` (256-item cap, statuses, merge semantics).
- **Before:** hydrate `env[:todo_store]` from history if empty; install the `todo` tool.
- **Compaction hook:** `Compaction` calls `env[:todo_store].format_for_injection` and
  re-injects active items ("[Your active task list was preserved across context
  compression]").
- **Tests:** write/merge/read; hydration from a resumed transcript; re-injection after a
  forced compaction.

### 2.6 `Hermes::Middleware::Nudge`
- **Ports:** `agent/turn_context.py:685` (memory, per user turn), `conversation_loop.py:1776`
  (skill, per tool-iteration), `tool_executor.py:605-608` (use-resets), `turn_finalizer.py:733`.
- **Before (turn):** hydrate once from history (`prior_user_turns % interval`); increment the
  memory counter; at interval → `env[:review_memory] = true`, reset. Gated on the memory
  store being installed.
- **After (turn):** apply use-resets from the event stream (`memory` tool used → memory
  counter 0; `skill_manage` used → skill counter 0); add the turn's iteration delta
  (`env[:current_iteration]`); at interval (and `skill_manage` unused) →
  `env[:review_skills] = true`, reset.
- **Placement:** inner of BackgroundReview (§6.3) — after-phase unwind order.
- **Config:** `memory.nudge_interval: 10`, `skills.creation_nudge_interval: 10`.
- **Tests:** exact-interval firing; resume hydration; both use-resets; skill flag visible to
  BackgroundReview's after-phase; interval 0 disables.

### 2.7 `Hermes::Middleware::PromptTiers`
- **Ports:** `agent/system_prompt.py:265` (`build_system_prompt_parts`),
  `conversation_loop.py:615` (`_restore_or_build_system_prompt`).
- **Before:** restore the persisted prompt verbatim when the session row has one and the
  runtime identity matches (model/provider lines); else build the three tiers —
  **stable** (SOUL.md or default identity, task-completion guidance, parallel-tool-call
  guidance) → **context** (workspace snapshot, AGENTS.md/CLAUDE.md, caller system message) →
  **volatile** (skills index, memory snapshot, user profile, timestamp) — hand to SessionStore
  to persist, set `env[:system_prompt]`.
- **Rebuild trigger:** only `Compaction` (via `Compaction#invalidate!` → next turn rebuilds,
  memory reloaded from disk).
- **Tests:** byte-identical across two turns of a session (compare digests); volatile change
  (new memory) does NOT rebuild within a session; rebuild after compaction picks it up.

### 2.8 `Hermes::Middleware::Clarify`
- **Ports:** `tools/clarify_tool.py` + `tools/clarify_gateway.py`. Supersedes brute's
  unimplemented `Middleware::Question` (060).
- **Before:** install `env[:clarify_handler]`; install the `clarify` tool
  (`question, choices≤4, multi_select`). Handler blocks the turn thread on user input with a
  timeout (default 3600s → returns "[user did not respond…]"). First choice labeled
  "(Recommended)".
- **Denied contexts:** subagents and cron agents install a handler that returns
  "unavailable" instead of blocking.
- **Tests:** blocking + answer resumes the loop; timeout returns the sentinel string;
  subagent context refuses.

### 2.9 `Hermes::Middleware::Delegation`
- **Ports:** `tools/delegate_tool.py`, `tools/async_delegation.py`.
- **Before:** install the `delegate_task` tool and `env[:delegation_queue]` (shared
  `Hermes::CompletionQueue`).
  - **Sync child:** build a sub-`Brute.agent` (leaf toolset: no delegate/clarify/memory/
    cronjob; ephemeral "YOUR TASK" prompt; own `env`), run inline, return
    `{status, summary, api_calls, duration, exit_reason}`.
  - **Background (default at top level):** thread + queue; tool returns
    `{status: "dispatched", delegation_id}` immediately; completion formats
    `[ASYNC DELEGATION COMPLETE — id]…--- RESULT ---` onto the queue.
  - **Control:** `action: list|steer|stop` (steer appends to the child's last tool result at
    its next iteration boundary — the child's own Steering middleware reads the same queue
    entry).
  - **Caps:** batch ≤ `max_concurrent_children` (3); depth ≤ `max_spawn_depth` (1);
    child `max_iterations` 50; summary cap 24k with spill file.
- **Owns:** `env[:delegation_depth]`, `env[:subagent_id]`.
- **Tests:** sync result shape; background dispatch returns immediately and a completion
  event lands on the queue; leaf cannot call delegate_task; steer reaches a running child;
  depth cap degrades orchestrator→leaf.

### 2.10 `Hermes::Middleware::ProcessRegistry`
- **Ports:** `tools/process_registry.py` + `terminal(background=true)` path.
- **Before:** install the `process` tool (`list|poll|log|wait|kill|write|submit|close`) and
  extend `terminal` with `background`/`notify_on_complete`. With notify: on process exit push
  `[IMPORTANT: Background process … exited (exit code N). … <2k tail>]` to the shared
  completion queue. Finite sessions (cron/one-shot) strip notify flags with a
  `notify_unsupported` note.
- **Owns:** `env[:process_registry]` (session_id → {pid, buffer, status}).
- **Tests:** spawn/poll/log/kill lifecycle; notify event on exit; flags stripped in finite
  sessions.

### 2.11 `Hermes::Middleware::CronSchedule`
- **Ports:** `cron/jobs.py`, `tools/cronjob_tools.py`. (The tick loop itself is driver-side —
  see §4.)
- **Before:** install the `cronjob` tool (`create|list|update|pause|resume|remove|run`)
  over the jobs store (jobs.json). Enforce: model/provider pins user-only, jobs created
  inside cron runs default disabled, injection scan on create.
- **Owns:** `env[:cron_store]`.
- **Tests:** schedule parsing (duration/every/cron-expr/ISO, timezone-anchored); create→due→
  fire; agent-cannot-pin-model guard; `[SILENT]` suppression marker honored by the driver.

### 2.12 ~~`Hermes::Middleware::BackgroundReview`~~ → driver code

**Not middleware — and that was a deliberate correction.** Hermes forks a daemon thread
because it is a long-lived app; our process is one turn (systemd-timer model), so the
review is simply **a second `Brute.agent` started right after the first returns**, in
`main.rb`'s straight-line code. The logic lives in `Hermes::Review` (`review.rb`) — plain
functions: `select_prompt` (memory/skills/combined + whitelist suffix + focus), `digest`
(tail-24, routed-model only), `summarize` (successful memory/skill_manage actions past the
replayed history; off/on/verbose). See §5.

---

## 3. Per-iteration middleware (inside the loop)

### 3.1 `Hermes::Middleware::Interrupt`
- **Ports:** `_interrupt_requested` check at `conversation_loop.py:1724`; `tools/interrupt.py`.
- **Before:** if the shared flag is set → `env[:should_exit] = { reason: "interrupted" }`,
  skip inner. Flag is set by the driver (/stop, Ctrl+C) or a watchdog (cron inactivity,
  delegation staleness).
- **Tests:** set flag mid-loop → loop exits before next LLM call; reason recorded.

### 3.2 `Hermes::Middleware::Steering`
- **Ports:** steer drain at `conversation_loop.py:1783`; redirect at `:1710`. picoclaw's
  `steering_loop.rb` is the working prototype.
- **Before:** drain `env[:steer_queue]`; append formatted marker to the **last `:tool`
  message** (scan backwards); if none exists yet, leave queued. Redirect: merge into the
  turn's originating user message for persistence.
- **Tests:** steer during a tool loop reaches the very next API call; transcript keeps strict
  alternation; steer with no tool message stays pending.

### 3.3 `Hermes::Middleware::IterationBudget`
- **Ports:** `IterationBudget`, `_budget_grace_call`, `handle_max_iterations`.
- **Before:** when `env[:current_iteration] > max` → do **not** run the normal inner pass;
  instead run one **grace call**: `env[:tools] = []` + wrap-up nudge message through the
  inner stack once, then `env[:should_exit] = { reason: "max_iterations" }`.
- (Subsumes brute's `MaxIterations` + `Summarize`.)
- **Tests:** loop never exceeds max+1 LLM calls; grace call is tool-free; exit reason set.

### 3.4 `Hermes::Middleware::Compaction`
- **Ports:** `agent/context_compressor.py` (+ `docs/micro-compaction.md`).
- **Before (each iteration):** estimate context from `env[:usage]` (TokenUsage) → over
  `threshold` (0.50 of window; 0.75 floor for small windows) → compact: LLM-summarize the
  middle via the auxiliary model, keep `protect_last_n` (20) + ≥1 real user turn, rebuild
  `env[:messages]` with valid alternation, re-inject todo (2.5), flag PromptTiers for
  rebuild, mark rewritten messages so SessionStore archives rather than double-writes.
- **Overflow path:** shares the `COMPACTOR` object with ErrorRecovery (413 → compact → retry,
  bounded by `max_attempts: 3`).
- **Modes:** `micro_compact: false` (fold one oldest exchange per turn), `idle_seconds:`
  (time-based pre-compact on resume).
- **Tests:** threshold trip on a scripted token sequence; tail invariants (≥1 real user turn
  survives); alternation valid after rebuild; todo re-injected; prompt rebuild follows.

### 3.5 `Hermes::Middleware::ToolDispatch`
- **Ports:** `model_tools.py:1170` `handle_function_call` + the interception at
  `agent/agent_runtime_helpers.py:2914`. Extends brute's `ToolPipeline` (070).
- **Before:** `env[:tools] = @tools` (static set + middleware-provided tools collected from
  env: todo, memory, skills×3, cronjob, delegate_task, process, clarify).
- **After (response has tool_calls):** per call — **name repair** (fuzzy, cutoff 0.7) →
  **intercept** agent-state tools (route to env stores) → execute each call through its
  **per-tool middleware pipeline** (§4 — this is where coercion, approval, caps, audit live;
  they are *tool-call middleware*, not dispatch conditionals) → parallel via `Async::Barrier`
  (read-only concurrency; dangerous calls serialize) → append `:tool` messages in original
  call order → report `skill_manage` use to Nudge.
- **Why name repair and interception stay here and not in §4:** they act *between* tools —
  repair must happen before a pipeline can be selected by name, and interception chooses
  *which* pipeline (env-state handler vs static handler). Everything that acts *within* one
  call is §4 middleware.
- **Also dispatch-level:** tool-search bridge (`tool_call` unwraps and recurses so Audit
  sees the real name), context injection (`task_id`, `session_id`, `enabled_tools` → each
  pipeline's `env[:metadata]`).
- **Tests:** typo repair (`"ReadFile"` → `read_file`); parallel execution order preserved;
  interception reaches the env store, not the static handler; every call observable via
  Audit events.

### 3.6 `Hermes::Middleware::ErrorRecovery`
- **Ports:** `agent/error_classifier.py`, empty-response recovery
  (`run_agent.py:1942`), truncated-call/length retries, fallback model.
- **Around the LLM call:** classify failures (rate-limit/timeout/auth/billing/overflow/
  content-policy) → per-class retry with backoff; overflow → `COMPACTOR.compact!` then retry
  (≤3); empty content → synthetic retry with ephemeral-flagged scaffolding (dropped after,
  never persisted); configured `fallback_model` → one switch per turn. Unrecoverable →
  append a terminal assistant message explaining the failure, set should_exit.
- **Tests:** each classified error takes its path; ephemeral scaffolding absent from the
  persisted transcript; fallback used once.

### 3.7 `Hermes::Middleware::TokenUsage`
- **Ports:** per-turn token accounting (`agent/context_breakdown.py` subset).
- **After each call:** record `env[:usage]` = {input, output, total, call_count} from the
  transport's usage payload; cumulative totals in `env[:metadata][:usage]` (feeds `/usage`,
  Compaction estimates, delegation cost fields).
- **Tests:** usage accumulates across iterations; present in the final env.

---

## 4. Tool-execution middleware — the per-call stack (`Hermes::Middleware::Tool::*`)

Every tool execution is itself a middleware pipeline (`Brute::Turn::ToolPipeline`):
`env = { name:, arguments:, result:, events:, metadata: }` flows toward the handler proc.
`ToolDispatch` (§3.5) builds each tool's pipeline with this canonical stack. Approval,
safety, caps, audit — **these are middleware**, the canonical use the pattern was invented
for: policy as composable layers around execution, where any layer may short-circuit
(Rack-style) without the handler ever running.

Canonical order (outer → inner; before-phases run top-down, after-phases unwind bottom-up):

```
use Hermes::Middleware::Tool::CoerceArgs        # before
use Hermes::Middleware::Tool::AvailabilityGate  # before (short-circuit)
use Hermes::Middleware::Tool::SafetyGuard       # before (normalize + policy on args)
use Hermes::Middleware::Tool::EditApproval      # before (write tools, editor sessions)
use Hermes::Middleware::Tool::Approval          # before (the layered human gate)
use Hermes::Middleware::Tool::ReadLoopGuard     # before+after (anti-loop tracking)
use Hermes::Middleware::Tool::TransformResult   # after only (last word before context)
use Hermes::Middleware::Tool::Audit             # around (events + duration)
use Hermes::Middleware::Tool::ResultCaps        # after (truncate/spill)
use Hermes::Middleware::Tool::SecretRedact      # after
use Hermes::Middleware::Tool::ResultNormalize   # after (contract enforcement)
use Hermes::Middleware::Tool::ErrorWrap         # around (innermost guard)
run ->(env) { tool handler }                    # the tool itself
```

The 12, each with its hermes source:

### 4.1 `CoerceArgs` (before)
Ports `coerce_tool_args` (`model_tools.py:777`). Schema-guided string→number/bool/array/
object coercion, JSON-string arg parsing, sanitized-key unrename. First, so every downstream
layer sees typed args.

### 4.2 `AvailabilityGate` (before, short-circuits)
Ports registry `check_fn` + TTL cache (`tools/registry.py:324` — 30s TTL, 60s last-good
grace). Unknown tool → `tool_error("Unknown tool: …")`; check_fn false → unavailable error.
Never calls inner on failure.

### 4.3 `SafetyGuard` (before)
Ports the `tool_request` middleware position (`docs/middleware/README.md:96`). Workspace
confinement, path normalization. Runs **before** Approval so policy evaluates the rewritten
values — hermes' own rule ("tool request middleware runs before approvals").

### 4.4 `EditApproval` (before)
Ports `maybe_require_edit_approval` (`model_tools.py:1400`). Guards `write_file`/`patch` in
ACP/editor sessions; fail-closed. No-op elsewhere.

### 4.5 `Approval` (before, short-circuits)
Ports the whole gate in `tools/approval.py`: hardline blocklist (pre-yolo: `rm -rf /`,
fork bomb…) → user deny-globs → yolo bypass → permanent allowlist (globs; compound commands
excluded) → tiered danger patterns (deobfuscation-aware) → cron-context deny
(`approvals.cron_mode=deny`) → smart guardian LLM (`approvals.mode="smart"`;
approve = one-command-only; consecutive-denial breaker at 3) → human
`once/session/always` prompt, **300s fail-closed timeout** ("silence is not consent").
`always` persists to the allowlist. On deny: never calls inner; sets `env[:result]` to the
`BLOCKED …` JSON — and the unwind still gets Audited, so the denial itself is observable.

### 4.6 `ReadLoopGuard` (before+after)
Ports the read-loop tracker (`model_tools.py:1440`). Detects re-reading the same paths;
resets on any non-read tool; nudges/blocks on repetition.

### 4.7 `TransformResult` (after; outermost after-phase)
Ports `transform_tool_result` (`model_tools.py:1533`). First-string-wins replacement — the
final word before the result enters context.

### 4.8 `Audit` (around)
Ports `post_tool_call` (`model_tools.py:1116`). Emits `tool_call_start` before and
`tool_result` after with `{tool_name, args, result, duration_ms, status, error_type}` onto
`env[:events]`. Inside TransformResult, matching hermes (post_tool_call fires before
transform).

### 4.9 `ResultCaps` (after)
Ports `max_result_size_chars` (`registry.py:1148`) + terminal spill. Per-tool cap
(terminal/execute_code 100k), 40/60 head/tail truncation with marker, overflow spills to a
file + path reference. Runs after Redact: truncation is the final context-bound guarantee.

### 4.10 `SecretRedact` (after)
Ports `agent.redact.redact_sensitive_text`. Scrubs credentials/tokens from outputs
(terminal, execute_code especially).

### 4.11 `ResultNormalize` (after)
Ports `_normalize_handler_result` (`registry.py:1071`). Enforces the JSON-string contract
(sole exception: the multimodal envelope); re-bounds oversized `{"error":…}` strings.

### 4.12 `ErrorWrap` (around; innermost)
Ports the top-level catch + `_sanitize_tool_error` (`model_tools.py:743`). Exception →
`"Tool execution failed: {Type}: {msg}"` JSON; strips XML role tags/fences/CDATA;
`[TOOL_ERROR]` prefix; 2048-char cap. Innermost, so Audit always sees a wrapped error
result, never a raw exception.

**Correspondence proof:** `coerce_tool_args`→4.1 · check_fn/availability→4.2 · `tool_request`
middleware→4.3 · ACP edit approval→4.4 · `tools/approval.py`→4.5 · read-loop tracker→4.6 ·
`transform_tool_result`→4.7 · `post_tool_call`→4.8 · `max_result_size`+spill→4.9 ·
redaction→4.10 · dispatch normalization→4.11 · top-level error wrap→4.12. Nothing in
`handle_function_call` is unaccounted for.

---

## 5. Not middleware (by design)

Driver machinery only (`main.rb`, feeding new turns through the front door):

- `Hermes::CompletionQueue` — one queue; Delegation/ProcessRegistry/cron-run completions
  land here; the driver drains it between user inputs and starts **new turns** with the
  synthetic message (the hermes gateway watcher pattern).
- **The review (learning loop)** — when a nudge fires, `main.rb` runs a second
  `Brute.agent` right after the first returns (logic in `Hermes::Review`, review.rb).
  Only memory/skill_manage tools, no SessionLog (persistence isolation is structural),
  write origin pinned to `background_review` for the run. Hermes forks a thread because
  it's long-lived; we just run the next agent.
- **Cron ticker** — 60s thread: flock, due jobs, watchdog (600s inactivity hard
  interrupt), delivery wrapper, `[SILENT]`, per-job `context_from` chaining.
- **Heartbeat** — idle-only recurring instruction ("do not invent work" frame).
- **Curator** — timer-driven skill gardener (stale→archive, never delete, tar.gz backups).
- **MCP / kanban dispatcher / multi-backend terminal envs** — later-phase machinery; tool
  scaffolds already exist.

## 6. Ordering constraints that are load-bearing

1. `SessionStore` outside `PromptTiers`: the prompt is persisted/restored through it.
2. `Memory`/`Skills`/`Todo` before `PromptTiers`: the volatile tier reads their env state.
3. `Nudge` sits just before the loop: its flags (`:review_memory` / `:review_skills`) must
   be final when the turn ends — the driver reads them after `start` returns to decide
   whether to run the review agent.
4. `Steering` before the LLM call on every iteration — hermes drains *pre-API* for a reason.
5. `IterationBudget` above `Compaction`: an exhausted budget must not compact — it exits.
6. `ToolDispatch` directly above the recovery/usage wrappers so it sees the *final*
   (post-retry) response.
7. The review agent never includes `SessionStore`/`SessionLog`: persistence isolation is
   structural — the second pipeline simply has no persistence middleware in it.
8. `CoerceArgs` first in the tool stack: every downstream layer sees typed args.
9. `SafetyGuard` before `Approval`: policy evaluates the normalized/rewritten values
   (hermes: "tool request middleware runs before approvals").
10. `ErrorWrap` innermost: `Audit` always observes a wrapped error result, never a raise.
11. `Audit` inside `TransformResult`: hermes fires `post_tool_call` before
    `transform_tool_result` — events describe the pre-transform result.
12. `ResultCaps` after `SecretRedact`: truncation/spill is the final context-bound guarantee.
