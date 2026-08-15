# Hermes Agent → brute — Feature Catalogue & Porting Strategy

Source studied: `github.com/nousresearch/hermes-agent` @ main (clone: `~/src/agents/hermes-agent`,
~890k LOC Python). Target: this directory, a port built **middleware-by-middleware** on the
`brute` gem (Rack-style turn pipeline: an `env` hash flows through a middleware stack toward a
terminal proc that calls the LLM).

Every feature below lists: **what it does → exact mechanics → config/defaults → source refs**.

---

## 0. The two sacred invariants (design lens for the whole port)

1. **Prompt caching is sacred.** The system prompt is built once per session, persisted in the
   session DB, and reused *byte-for-byte* on every later turn. Nothing may mutate past context,
   swap toolsets, or rebuild the prompt mid-conversation — the single exception is compression.
   (`hermes-agent/AGENTS.md`, `agent/conversation_loop.py:615` `_restore_or_build_system_prompt`)
2. **Strict role alternation.** Never two same-role messages in a row; never inject a synthetic
   user message mid-loop. Every proactive event (steer, cron delivery, delegation completion)
   is either appended onto an existing `tool` message or fired as a *brand-new turn*.
   Ephemeral recovery scaffolding is marked and never persisted
   (`run_agent.py:1942` `_drop_trailing_empty_response_scaffolding`, `_DB_PERSISTED_MARKER`
   idempotent flush at `run_agent.py:2000`).

Corollary for brute: message-list mutations belong to well-defined middleware points;
anything user-visible-but-synthetic is a new turn through the front door.

---

## 1. Core turn engine

### 1.1 The agent loop
`agent/conversation_loop.py:1709` — synchronous:

```python
while (api_call_count < agent.max_iterations
       and agent.iteration_budget.remaining > 0) or agent._budget_grace_call:
    if agent._interrupt_requested: break            # user /stop
    drain_pending_redirect()                        # mid-turn user correction
    drain_pending_steer()                           # appended onto LAST TOOL message
    api_call_count += 1
    response = llm_call(messages, tools)            # streaming or plain
    if response.tool_calls: dispatch each (concurrent when independent); append tool results
    else: return response.content                   # final answer
```

- `max_iterations` default **90** (CLI), subagents **50**
  (`run_agent.py:446`, `tools/delegate_tool.py:3464`).
- Per-iteration activity heartbeats (`_touch_activity`) feed the cron/kanban watchdogs.
- brute counterpart: `Middleware::Loop::ToolResult` + `MaxIterations` — already exists.

### 1.2 Iteration budget & the grace call
`IterationBudget(max_iterations)`; when the budget runs out mid-tool-loop, the agent gets
**one final grace call** (`_budget_grace_call`) to wrap up in text instead of dying on a tool
result. Max-iterations exit goes through `handle_max_iterations`
(`agent/chat_completion_helpers.py`) which appends a recognized runtime nudge user-message and
asks for a final summary. brute counterpart: `Middleware::Summarize` (004) is almost exactly
this (final tool-free call after the loop).

### 1.3 Interrupts & steering
- **Interrupt**: `_interrupt_requested` flag checked at the top of every iteration and inside
  long tool waits; `/stop` sets it, force-releases session locks, invalidates queued turns.
- **Hard interrupt**: `request_hard_interrupt(agent, reason)` — used by the cron inactivity
  watchdog; aborts in-flight sockets.
- **/steer (mid-loop steering)**: user text sent while the model is working is drained
  *before the next API call* and appended to the **last tool-role message** via
  `format_steer_marker` — never a new user message mid-loop (role alternation!)
  (`agent/conversation_loop.py:1783`). If no tool message exists yet, it stays pending.
- **Redirect**: a correction during an active turn rewrites the pending direction and is
  merged into the original user message for persistence.
- brute counterpart: picoclaw's `middleware/steering_loop.rb` is a working prototype of this.

### 1.4 Error taxonomy & recovery
- Classified errors (`agent/error_classifier.py`): rate-limit, timeout, auth, billing,
  content-policy, context-overflow — each with distinct retry/surface policy.
- **Empty-response recovery**: synthetic retry scaffolding stamped with flags, dropped from
  the transcript tail afterwards, never persisted.
- **Truncated tool-call / length-continue retries** with separate counters.
- **Fallback model**: on classified failure, switch to `fallback_model` once per turn.
- **Context-overflow (413)**: triggers an immediate compression attempt, then retry
  (bounded by `compression.max_attempts`, default 3).
- Content-policy refusal → `_content_policy_blocked_result`, optionally one fallback try.

### 1.5 Concurrent tool execution
Independent tool calls in one assistant message run **concurrently** (read-only always;
path-scoped file ops when non-overlapping); results are appended in the original call order
for determinism. The system prompt teaches batching (`PARALLEL_TOOL_CALL_GUIDANCE`).
brute counterpart: `Middleware::ToolPipeline` already runs calls in parallel via
`Async::Barrier` and sorts results back into call order. ✅ parity.

### 1.6 Turn persistence
SQLite session store (`hermes_state.py`, FTS5 in `hermes_state_search.py`). Append-only flush
with an intrinsic per-message `_DB_PERSISTED_MARKER` (idempotent across exit paths), one
transaction per batch, system-prompt snapshot stored on the session row, crash-resilience
persist of the user message *before* the first API call. Ephemeral scaffolding skipped.
brute counterpart: `Middleware::SessionLog` (JSONL) + `Middleware::Checkpoint` exist;
FTS search does not.

---

## 2. Context engineering

### 2.1 System prompt — three cache tiers
`agent/system_prompt.py:265` `build_system_prompt_parts` returns `{stable, context, volatile}`.
Every block is gated on `valid_tool_names` — guidance for an unloaded tool never ships.

- **stable** (cross-session cached prefix), in order:
  1. SOUL.md identity (fallback: `DEFAULT_AGENT_IDENTITY`)
  2. `HERMES_AGENT_HELP_GUIDANCE` (pointer to the hermes-agent skill + docs)
  3. `TASK_COMPLETION_GUIDANCE` — never stop at a stub, never fabricate
     (`agent.task_completion_guidance` default true)
  4. `PARALLEL_TOOL_CALL_GUIDANCE` — batch independent tool calls
     (`agent.parallel_tool_call_guidance` default true)
  5. Per-tool guidance: `MEMORY_GUIDANCE`, `SESSION_SEARCH_GUIDANCE`, `SKILLS_GUIDANCE`,
     `KANBAN_GUIDANCE` (dispatcher-spawned workers only)
  6. `STEER_CHANNEL_NOTE` — steering arrives inside tool results
  7. `computer_use` guidance (host-platform-rendered wording)
  8. Nous subscription prompt
  9. Tool-use enforcement (`agent.tool_use_enforcement`: auto/true/false/list) +
     `GOOGLE_MODEL_OPERATIONAL_GUIDANCE` (gemini/gemma) / `OPENAI_MODEL_EXECUTION_GUIDANCE`
     (gpt/codex/grok)
  10. Alibaba model-identity workaround
  11. Environment hints (WSL/Termux)
  12. Coding operating brief (workspace posture, model-family edit-format nudge)
  13. Environment-probe line (python/pip/uv/PEP-668; emits nothing when clean; local only)
  14. Active-profile hint (which HERMES_HOME; cross-profile write warning)
  15. Platform hint (`PLATFORM_HINTS` + `platform_hints.<platform>` config override)
- **context** (session-stable, cwd-dependent): coding workspace snapshot (git state) +
  trailing coding parts; caller-supplied `system_message` (`ephemeral_system_prompt` is
  deliberately NOT here — injected at API-call time only, never touches the stored prompt);
  context files via `build_context_files_prompt` (soul skipped when already identity;
  install-tree fallback only for cli/tui).
- **volatile** (rebuild tail), in order:
  1. **Skills index** — deliberately at the FRONT of the volatile band: on longest-prefix
     caches an unchanged index still falls inside the reused prefix; focus mode can demote
     non-coding categories to names-only (`agent/prompt_builder.py:1991`)
  2. Memory block (frozen snapshot, `memory_enabled` gate)
  3. USER.md block (`user_profile_enabled` gate)
  4. External memory provider block
  5. Frozen plugin prompt sections (anchored "after_memory")
  6. Timestamp line — `Conversation started: <Weekday, Month DD, YYYY>` — **date-only**:
     minute precision would bust the prefix cache on every rebuild (model can query
     wall-clock via tools). Plus Session ID / Model / Provider / Platform when configured.

Lifecycle: built once per session → persisted on the session DB row → **restored verbatim**
on later turns (validated against runtime identity lines — model/provider) → rebuilt **only
after compression** (`invalidate_system_prompt` also reloads memory from disk) →
`reconstruct_static_prefix` preserves the Anthropic two-block cache layout on restore.
Plugin-registered prompt sections are frozen into the stored bytes.

brute counterpart: `Middleware::SystemPrompt` (020) + `Middleware::Skills` (025) +
`Brute::Prompts` templates. The 3-tier discipline is a port-time policy, not new machinery.

### 2.2 Context files & persona
SOUL.md = persona/identity (loaded unless `skip_context_files`; cron loads persona but skips
cwd project files). AGENTS.md/CLAUDE.md = project instructions, loaded per working directory
(cron `workdir` jobs load that dir's AGENTS.md). Context-file size caps scale to the model's
context window; truncation warnings surface as status events.

### 2.3 Compression
`agent/context_compressor.py` (~7.4k lines) + `agent/conversation_compression.py`.

- **Trigger**: estimated context ≥ `compression.threshold` × context_length.
  Default **0.50**; models <512K floored at **0.75**. Optional absolute
  `compression.threshold_tokens`. Per-model overrides via `model_thresholds`.
- **Algorithm**: LLM-summarize the middle, keep a recent **tail** of
  `compression.target_ratio` (0.20) of threshold, always keep `protect_last_n` (**20**)
  messages and ≥`min_tail_user_messages` (**1**) real user turns verbatim. Summary reinserted
  so role alternation stays valid; todo list re-injected after compression
  ("[Your active task list was preserved across context compression]",
  `tools/todo_tool.py:116`).
- **Attempts**: `compression.max_attempts` (**3**) shared by preflight/pre-API/overflow paths.
- **Auxiliary model**: `auxiliary.compression.{provider,model,base_url,timeout=120,
  reasoning_effort}` — summarization can run on a cheaper model.
- **Micro-compaction** (`compression.micro_compact`, default off): after each normal turn,
  fold the single oldest unabsorbed *exchange* (assistant + tool results up to next user
  msg) into a running summary marker — amortizes cost, breaks prefix cache every turn.
  (`docs/micro-compaction.md`)
- **Idle compaction** (`idle_compact_after_seconds`): resume after long idle → compact up
  front.
- **Rotation**: oversized first turn can archive-and-rotate into a child session
  (`parent_session_id`).

### 2.4 Tool-output hygiene
- Per-tool `max_result_size_chars` (terminal/execute_code 100k); error strings capped at
  **2048** chars and sanitized (strip XML role tags/fences, `[TOOL_ERROR]` prefix).
- Head/tail truncation **40%/60%** with explicit truncation metadata (terminal overflow tees
  to a spill file under `cache/terminal-output/`, 5MB cap, 7-day GC).
- Hook-injected blobs >10k spill to `hook_outputs/` with head/tail previews.
- brute counterpart: `Brute::Truncation` safety net inside `ToolPipeline` ✅ (already there).

---

## 3. The learning loop (the crown jewels)

### 3.1 Memory — `memory` tool + MEMORY.md / USER.md
`tools/memory_tool.py`. One tool, two targets:
`memory(target: "memory"|"user", action: "add"|"replace"|"remove"|"batch", content, old_text,
operations[])`.
- `memory` target → MEMORY.md (agent's own notes: situation, state of operations).
- `user` target → USER.md (who the user is: persona, preferences, expectations).
- Both render into the volatile tier of the system prompt.
- Writes are mirrored to external memory providers via `memory_manager.notify_memory_tool_write`.
- Agent-loop intercepted (the store is agent state) — in brute: a tool whose handler closes
  over per-turn state provided by a middleware.

### 3.2 Memory nudge
**A nudge is not a message** — nothing is injected into the conversation. Nudges are two
counters that gate the after-turn background review fork (§3.5); the "nudging" content lives
in the review prompts (Appendix A).

Memory nudge — unit: **user turns**. Counter `_turns_since_memory`, interval
`memory.nudge_interval` (default **10**, `agent/agent_init.py:1744`). Checked at **turn
setup** (`agent/turn_context.py:685`), only when the memory tool + store exist: counter ≥
interval → `should_review_memory=True`, counter resets. **Hydrated on resume**
(`turn_context.py:643`): prior user turns are counted from persisted history and the counter
is seeded with `prior_user_turns % interval` — a resumed session keeps the cadence.

### 3.3 Skills — procedural memory
- Format: `SKILL.md` + frontmatter (`name`, `description` ≤60 chars, `version`, `platforms`,
  `metadata.hermes.{tags,category,related_skills,config}`) + optional `references/`,
  `templates/`, `scripts/` dirs. Target shape: **class-level umbrella skills**, not
  one-per-session narrow entries.
- Tools (toolset `skills`): `skills_list`, `skill_view` (load full SKILL.md into context),
  `skill_manage(action: create|edit|patch|delete|write_file|remove_file, ...)`.
- Slash commands: `/<skill-name>` injects the skill as a **user message** (cache-safe),
  scanned per session (`agent/skill_commands.py`).
- Write protection: bundled / hub-installed / pinned / user-owned skills are refused to
  autonomous writers; only `created_by: agent` (curator-managed) skills are fair game.
- Usage telemetry sidecar `skills/.usage.json`: `use_count, view_count, patch_count,
  last_activity_at, state(active|stale|archived), pinned` (`tools/skill_usage.py`).
- Skills Hub (`tools/skills_hub.py`): install from agentskills.io; `optional-skills/` ship
  inactive.
- brute counterpart: `Brute::Skill` + `Middleware::Skills` exist; see HOW_SKILLS_WORK.md.

### 3.4 Skill nudge
Unit: **tool-calling iterations**. Counter `_iters_since_skill`, interval
`skills.creation_nudge_interval` (default **10**, `agent_init.py:1859`). Incremented per loop
iteration (`agent/conversation_loop.py:1776`); **reset to zero whenever `skill_manage` is
actually used** (`agent/tool_executor.py:608`) — it is a "you haven't improved your skills
lately" clock, and using the skill tools IS the improvement. Checked at **turn end**
(`agent/turn_finalizer.py:733`): ≥ interval + `skill_manage` available →
`should_review_skills=True`, counter resets.

The shared trigger (`turn_finalizer.py:750`): the fork spawns only when a final response
exists AND the turn wasn't interrupted AND it's not a cron agent AND at least one flag fired.
It runs **after the answer is delivered**, gets the memory/skill/combined prompt by which
flags fired, and is **cancelled if a new live turn starts**. Best-effort throughout.

### 3.5 Background review — the learning fork
`agent/background_review.py`, spawned from `agent/turn_finalizer.py:750` **after the response
is delivered**, when `(review_memory or review_skills)` and not interrupted and not cron.

- Forks a **new AIAgent** on a daemon thread with a snapshot of the conversation
  (`_digest_history`, tail 24 messages), `skip_background_review=True`, nudge intervals 0,
  approvals auto-denied, **persistence disabled** (the fork must never write to the session
  store — it shares the session_id for cache warmth).
- Runs one of three prompts (verbatim in Appendix A): `_MEMORY_REVIEW_PROMPT`,
  `_SKILL_REVIEW_PROMPT`, `_COMBINED_REVIEW_PROMPT` (both triggers → combined).
  `/refine <focus>` appends a user-steering paragraph.
- The fork has the `memory` and `skill_manage` tools; it writes to MEMORY.md/USER.md and the
  skills library — never to the chat.
- A new live turn **cancels** an in-flight review (`_pending_review.interrupt("superseded")`).
- Action summary surfaces via `background_review_callback` / `display.memory_notifications`.
- Routable to a cheaper model via `auxiliary.background_review.{provider,model}`.

### 3.6 Curator — skill lifecycle gardener
`agent/curator.py` + `curator_backup.py`. Config `curator:`
(`enabled, interval_hours, min_idle_hours, stale_after_days, archive_after_days, backup.*`).
- Periodic LLM review of **agent-created skills only**; transitions active→stale→archived;
  **never deletes** (archive → `skills/.archive/`, restorable); tar.gz backup before each run.
- Pinned skills exempt from everything; `skill_manage(delete)` refuses pinned.
- CLI: `hermes curator status|run|pause|resume|pin|unpin|archive|restore|prune|backup|rollback`.

### 3.7 Session search — cross-session recall
FTS5 over the SQLite session store. Tool `session_search(query, role_filter, limit=3,
session_id, around_message_id, window=5, sort, profile)` — returns DB content directly (the
aux-LLM summarization was removed). Lets the agent search *its own past conversations*.

### 3.8 External memory providers (plugins/memory/)
`MemoryProvider` ABC: `sync_turn(turn_messages)`, `prefetch(query)`, `shutdown()`,
`post_setup()`. Built-ins: **honcho** (dialectic user modeling — builds/queries a deepening
model of the user), mem0, supermemory, byterover, hindsight, holographic, openviking,
retaindb. Cron skips them (`skip_memory=True`). → Port as an optional adapter later; not core.

---

## 4. Autonomy infrastructure

### 4.1 Cron
`cron/jobs.py` + `cron/scheduler.py` + agent-facing `cronjob` tool
(`action: create|list|update|pause|resume|remove|run`).

- **Job fields**: prompt, schedule, skills, `script` (pre-run; stdout injected into prompt),
  `no_agent` (script-only), `context_from` (chain upstream job outputs, 8k chars each),
  `workdir` (loads that dir's AGENTS.md), `deliver` (local|origin|all|platform:chat),
  `repeat{times,completed}`, `monitor_script/url/state` (hash-change wake gating),
  per-job `model/provider` pins (**user-owned only — the agent may not set them**;
  prompt-injection spend guard), `provider_snapshot` drift guard.
- **Schedules**: `"30m"` one-shot, `"every 2h"`, `"every monday 9am"`, 5-field cron, ISO
  one-shot. Naive timestamps anchor to the configured Hermes timezone.
- **Tick**: 60s daemon thread; cross-process non-blocking flock `.tick.lock`; due→dispatch;
  workdir jobs serialized on a single-thread pool (shared `TERMINAL_CWD` guard).
- **Catch-up**: grace = half the period clamped [120s, 7200s]; one-shots 120s; missed
  recurring jobs fast-forward but fire once now.
- **Watchdog**: inactivity ≥ `HERMES_CRON_TIMEOUT` (default **600s**) → hard interrupt.
- **Delivery**: wrapper `"Cronjob Response: {name} (job_id: ...)"` + manage hint; `[SILENT]`
  marker suppresses; failures classified to one-liners; deliveries land in their **own cron
  session** (or a dedicated thread) — never spliced into the main conversation
  (`attach_to_session`/`cron.mirror_delivery` opt-in mirrors as a user-role
  `"[Cron delivery: name]"` message).
- Cron agents run with `skip_memory=True`, `skip_background_review=True`,
  `quiet_mode=True`, and `cronjob/messaging/clarify/memory` policy-denied.
- Jobs created *from within a cron run* default to disabled (`cron.allow_agent_scheduling=false`).
- Ledger: `executions.db` (claimed|running|completed|failed), output retention 50 files/job,
  `usage_audit.jsonl` per fire.
- picoclaw already has `cron.rb` + `middleware/cron_schedule.rb` — a working subset.

### 4.2 Delegation — `delegate_task`
`tools/delegate_tool.py`, `tools/async_delegation.py`.

- **Single** (`goal`, `context`) or **batch** (`tasks: [{goal, context, role,
  output_schema}]`), parallel capped by `delegation.max_concurrent_children` (**3**).
- **Roles**: `leaf` (default; blocked from delegate_task/clarify/memory/send_message/cronjob/
  kanban) vs `orchestrator` (regains delegate_task; needs `delegation.orchestrator_enabled`
  and depth < `delegation.max_spawn_depth` default **1**).
- **Child context**: fresh agent, ephemeral system prompt (`YOUR TASK: ...` + CONTEXT +
  completion-style instructions), `skip_context_files`, `skip_memory`, no parent history —
  everything flows via `context`. Inherits model/provider/credentials unless
  `delegation.{model,provider,...}` pins. Own task_id (`sa-i-xxxxxxxx`); optional git
  worktree isolation (`delegation.worktree_isolation=false`).
- **Child limits**: `delegation.max_iterations` (**50**), `child_timeout_seconds` (**0** =
  none; staleness watchdog 450s idle / 1200s in-tool), approvals auto-deny
  (`subagent_auto_approve=false`).
- **Background (the default at top level)**: durable SQLite ledger + daemon executor; tool
  returns `{status: "dispatched", delegation_id}` immediately — "Do not wait or poll".
  On completion, an event goes on `process_registry.completion_queue`; a watcher (2s poll)
  formats `[ASYNC DELEGATION COMPLETE — id] ... --- RESULT ---` and injects it as a
  **synthetic internal user message through the front door** (new turn; alternation + cache
  intact). Delivery acked in the ledger (max 8 attempts, 48h replay cap).
- **Control**: `delegate_task(action: list|steer|stop, subagent_id, message)` — steer appends
  to the child's last tool result at its next iteration boundary.
- **Results**: `{status, summary, api_calls, duration, tokens, cost_usd, tool_trace,
  exit_reason, schema_valid, live_transcript}`; summaries capped vs parent context headroom
  (floor 2000, ceiling `delegation.max_summary_chars` **24000**), overflow spills to
  `cache/delegation/`. Optional `output_schema` (JSON Schema) with one validation retry.
- brute counterpart: spawn a sub-`Brute.agent` pipeline per child (own env, own middleware
  stack minus memory/clarify/delegate); background = thread + completion queue drained by the
  REPL loop into a new turn. `delegate` becomes a **tool**, the queue/drain is a **middleware**.

### 4.3 Background terminal processes
`terminal(background=true)` → process registry: `{session_id, pid}` immediately; manage via
`process` tool (`list|poll|log|wait|kill|write|submit|close`). With
`notify_on_complete=true`, a watcher (5s) fires a synthetic turn on exit:
`[IMPORTANT: Background process ... exited (exit code N). Command: ... Output: <2000-char
tail>]`. User-facing verbosity: `display.background_process_notifications` =
concise|all|result|error|off. Finite sessions (cron, one-shot) strip the flags with a
`notify_unsupported` notice.

### 4.4 Heartbeat — user-owned proactive turns
`/heartbeat every <interval> <prompt>` (min 60s, persisted per session). Fires **only when
the session is idle**; injects a user turn:
`[Heartbeat — recurring instruction, fires every N] <prompt> "If there is nothing meaningful
to do or report... reply briefly that nothing has changed and stop — do not invent work."`
Missed ticks coalesce. picoclaw has `middleware/heartbeat_gate.rb`. ✅ precedent.

### 4.5 Kanban (multi-agent board)
SQLite board per `~/.hermes/kanban/boards/<slug>`, task DAG (`task_links`), dispatcher tick
60s (reclaim stale claims TTL 900s, promote ready, claim CAS, spawn `hermes -p <profile>`
worker subprocesses), failure circuit breaker (2 consecutive → auto-block), review lane
(reviewer force-loads `sdlc-review` skill), worker heartbeats, board isolation via env.
Multi-process coupling makes this a later-phase port; all 14 `kanban_*` tools are scaffolded.

### 4.6 Human-in-the-loop
- **Approval** (`tools/approval.py`): pipeline = container-skip → hardline blocklist
  (`rm -rf /`, fork bomb… — fires *before* yolo) → user deny-globs → yolo bypass → permanent
  allowlist (globs; compound commands excluded) → tiered dangerous-pattern detection →
  cron-context deny (`approvals.cron_mode=deny`) → **smart approval** (aux guardian LLM,
  `approvals.mode="smart"`) → human prompt: `[o]nce/[s]ession/[a]lways/[d]eny`, timeout
  **300s fail-closed** ("silence is not consent"). Consecutive-denial circuit breaker (3).
  Plugin `pre_tool_call` can escalate any tool into this gate.
- **Clarify**: `clarify(question, choices[≤4], multi_select)` — blocks the agent thread on an
  event until the UI answers (timeout `agent.clarify_timeout` **3600s** → "[user did not
  respond…]"). First choice auto-labeled "(Recommended)". Denied to subagents and cron.
  brute counterpart: `Middleware::Question` (060) is an unimplemented stub — we build it.
- **Sudo/secrets**: per-session cached sudo password callback; generic secret prompt.

### 4.7 Estop
`hermes pause` global sentinel (`agent/estop.py`) — cron ticker checks it before dispatch.
Brakes for unattended operation.

---

## 5. Tool system

### 5.1 Registry contract
`registry.register(name, toolset, schema, handler, check_fn:, requires_env:,
max_result_size_chars:, dynamic_schema_overrides:, is_async:, override:)`.
- Schemas = OpenAI function format `{"type":"function","function":{...}}`.
- Handlers return **JSON strings** (`tool_result()`/`tool_error()` helpers); one structured
  exception (multimodal envelope).
- `check_fn` = availability probe, TTL-cached 30s with 60s last-good grace.
- Generation counter bumps on mutation (memoization key for tool definitions).
- brute counterpart: `Brute::Tool` + `Brute::Tools::Adapter.wrap_all`; HOW_TOOLS_WORK.md.

### 5.2 Toolsets
`TOOLSETS` dict `{description, tools, includes, posture?}`; `_HERMES_CORE_TOOLS` = every
platform's base (terminal, process, file ops, web, skills, memory, todo, session_search,
clarify, execute_code, delegate_task, cronjob, browser, vision, image_gen, tts…).
Per-platform bundles `hermes-<platform>`; `tools.<platform>.enabled/disabled` config;
`_DEFAULT_OFF_TOOLSETS` (homeassistant, spotify, video_gen…) unless credentialed;
`_HERMES_WEBHOOK_SAFE_TOOLS` for untrusted input. For the port: one default set +
per-entry-point bundles (cli / cron / subagent-leaf / subagent-orchestrator).

### 5.3 Dispatch pipeline (order is load-bearing)
`model_tools.py:1170` `handle_function_call`:
1. **coerce args** (schema-guided string→number/bool/array; JSON-string parsing)
2. tool-search bridge unwrap (if progressive disclosure active)
3. **`tool_request` middleware** (rewrite args)
4. **agent-loop interception** — `_AGENT_LOOP_TOOLS = {todo, memory, session_search,
   delegate_task}` run against agent state, not the registry
5. **`pre_tool_call` hook** → `{"action":"block"}` / `{"action":"approve"}` (fail-closed)
6. ACP edit approval for write tools
7. **`tool_execution` middleware** wraps dispatch
8. `post_tool_call` observer hook
9. `transform_tool_result` (first string wins) before the result enters context
Plus tool-name repair (fuzzy-match typos, cutoff 0.7).

brute note: brute's extension points are (a) middleware around the turn, (b) tool wrappers
around handlers (picoclaw `tools/tool_wrapper.rb`, `safety_guard.rb`). Hermes'
middleware/hook pipeline maps onto brute **tool wrappers** + one dispatch middleware.

### 5.4 `execute_code` — programmatic tool calling ("zero-context-cost turns")
`tools/code_execution_tool.py`. The agent writes a Python script; generated stubs call tools
over RPC; **only the script's stdout returns to context** — intermediate tool results stay
inside the child process.
- Allow-list: `web_search, web_extract, read_file, write_file, search_files, patch,
  terminal` ∩ session tools; terminal is foreground-only inside.
- Transport: newline-JSON `{tool, args, token}` over Unix socket (TCP on Windows); remote
  backends use tmp+rename request/response files polled via the sandbox itself.
- Child env scrubbed of secrets; token auth (`secrets.compare_digest`).
- Caps: 300s timeout, 50 tool calls, stdout 50KB (40/60 head/tail), stderr 10KB.
- RPC calls re-enter the full dispatch pipeline (hooks/approval fire).
- Port note: same design works in Ruby (unix socket + JSON lines; child could even be Ruby).

### 5.5 Terminal environments
7 backends (`local, docker, ssh, singularity, modal, daytona, vercel_sandbox`) behind
`BaseEnvironment`: `_run_bash`, `execute`, `cleanup`. Shell state persists via a **sourced
snapshot** per call (env/functions/aliases dumped+re-sourced; in-band CWD marker keeps cwd
across calls; failures never clobber cwd). Per-task env cache with idle reaper (300s).
For the port: local first; the snapshot technique is backend-agnostic and small.

### 5.6 MCP (client + server)
Per-server toolset `mcp-<server>`, tools namespaced `mcp__<server>__<tool>`; background
asyncio loop; per-server circuit breaker (5 failures→cooldown); on-disk schema cache for lazy
startup; OAuth; trust tiers; include/exclude globs; 4 utility tools per server
(list/read resources, list/get prompts). `mcp_serve.py` exposes Hermes itself as an MCP
server. MCP tool names are generated at runtime (`mcp__<server>__<tool>`), so they have no
static scaffolds — the client middleware arrives in a later phase.

### 5.7 Tool search (progressive disclosure)
When non-core tool surface exceeds budget, deferrable tools are replaced by 3 bridge tools
(`tool_search`, `tool_describe`, `tool_call`). Config `tools.tool_search.{enabled=auto,
threshold_pct=5.0,…}`. Core tools never deferred. Nice-to-have; cheap once toolsets exist.

### 5.8 `todo`
In-memory per-session store; `todo(todos?, merge?)`; statuses pending|in_progress|completed|
cancelled; caps 256 items/4000 chars; re-injected after compression. Agent-loop intercepted.

---

## 6. Scope

The **entire** hermes tool surface is ported — all 104 statically-registered tools have
scaffolds in `tools/` (generated mechanically from `tools/registry.py` `register()` calls
plus the plugin-registered sets: spotify, a2a, google_meet; see `tools/manifest.json`).
Nothing is excluded a priori. The phasing in §7.3 is an *implementation-order* decision
(what gets a real handler first), never an exclusion list — including kanban, MCP, browser,
media, and platform tools. Non-tool surfaces (messaging gateway, TUI, desktop app, billing,
provider plugins) have no brute-side counterpart yet and arrive when the port grows an
interface that needs them.

---

## 7. Porting strategy

### 7.1 The mapping rule (this is the key strategic insight)

Hermes itself separates: **model-facing verbs = tools**, **turn machinery = the loop +
hooks/middleware**, **time/process machinery = external daemons**. brute gives us the same
three slots:

| Hermes concept | brute slot |
|---|---|
| `memory`, `skill_manage`, `cronjob`, `delegate_task`, `clarify`, `todo`, `session_search` tools | **Tools** whose handlers close over per-turn state placed in `env` by a middleware (Hermes' "agent-loop intercepted tools" pattern) |
| Nudge counters, steering drain, interrupt, budget, compaction, persistence, prompt tiers | **Turn middleware** (wrap the loop / run before-after the inner stack) |
| Cron ticker, curator timer, process watcher, delegation completion queue drain | **Scheduler/driver code** outside the turn (threads feeding new turns through the front door — picoclaw's `cron.rb` + `main.rb` loop pattern) |
| pre_tool_call guardrails, approval, result transformation, `tool_request`/`tool_execution` contract | **Tool-execution middleware** — a `Brute::Turn::ToolPipeline` stack around every tool call (MIDDLEWARE.md §4). This is the canonical middleware use case: policy as composable, short-circuiting layers around execution |

### 7.2 The middleware stack

**Canonical definition: see `MIDDLEWARE.md`** — every middleware, its position
(per-turn / per-iteration / after-turn / driver), env contract, tools provided, hermes
source refs, and the load-bearing ordering constraints.

### 7.3 Build phases (each phase ships working, tested software)

1. **Skeleton turn** — main.rb (OpenRouter), SessionLog, PromptTiers (static+SOUL+AGENTS.md),
   Loop, MaxIterations+grace, ToolPipeline parity, core tools, truncation caps.
2. **Persistence & control** — SessionStore w/ markers, Interrupt, Steering, Todo, Approval
   wrapper (hardline + allowlist + once/session/always).
3. **Learning loop** — Memory (tool+files+volatile tier), Skills (index+view/manage+
   protection), Nudge counters, BackgroundReview fork, Curator timer.
4. **Context** — token accounting, Compaction (batch; micro later), output spill files.
5. **Autonomy** — Cron (jobs.json, tick, delivery, [SILENT]), Heartbeat, ProcessRegistry +
   notify, Delegation (sync → background w/ ledger).
6. **Advanced** — ExecuteCode RPC sandbox, SessionSearch FTS, Clarify, tool search.
7. **Polish** — fallback model, error taxonomy, estop, auxiliary-model routing
   (compression/review on a cheap model).

### 7.4 Test strategy

- `scampi` tests per middleware (in-file `__END__` describes, brute-style) + `bin/test`.
- Contract tests per feature: e.g. "steer never creates two user messages in a row",
  "compaction preserves ≥1 real user turn", "review fork writes nothing to SessionLog".
- A scripted fake-LLM terminal app (cue-card responses) drives multi-iteration tool loops
  without network.

---

## Appendix A — The three background-review prompts (verbatim)

See `agent/background_review.py:171-408`. They are the product's secret sauce — port them
unchanged first, tune later:

- `_MEMORY_REVIEW_PROMPT` — "Review the conversation above and consider saving to memory…
  Has the user revealed things about themselves… expectations about how you should behave…
  If nothing is worth saving, just say 'Nothing to save.' and stop."
- `_SKILL_REVIEW_PROMPT` — "Be ACTIVE — most sessions produce at least one skill update…"
  class-level umbrella doctrine, preference order (patch loaded → patch umbrella → add
  support file → create class-level), protected-skills list, do-NOT-capture list
  (environment failures, negative tool claims, transient errors, one-off narratives,
  unresolved failures).
- `_COMBINED_REVIEW_PROMPT` — both, with "memory = who the user is / skills = how to do
  this class of task for this user" split.
