# prime-agent → brute — Complete Tools & Middleware Catalogue

Source studied: `github.com/PrimeIntellect-ai/prime-agent` @ main
(clone: `/tmp/opencode/prime-agent`; TS host `packages/coding-agent/src`,
Python kernel runtime `prime-agent-runtime/src/rlm`). Target: this directory.
Companion to README.md — the README records stages 1–5 (wired); **this document
is the porting checklist for everything after stage 5**. The hermes example
(`examples/hermes`) proves the pattern: scaffold every tool/middleware as a
skeleton first, then fill implementations in one by one.

Status legend: **✅ wired** · **◐ partially wired** · **🔲 not started**

**Scaffold status:** stages 6–7 are filled (S1/S2 edit+websearch, M11 caps,
M12 mutation queue, M1 compaction, S6 compact skill — all ✅ below). Every
remaining 🔲/◐ item exists as a no-op skeleton, hermes-style: the 15
middlewares in `lib/prime_agent/middleware/` are pass-through (wired into
`main.rb` in their intended fill-in order); the kernel skills live in
`work/.brute/skills/<name>/` (`SKILL.md` + `lib/<name>.rb` returning
`{"error":"not implemented","skill":...}`, auto-discovered via the bootstrap
`skill_lib_glob` + `Brute::Prompts::Skills`); `KernelAgent.delete`/
`find_models` are stubs in `kernel_agents.rb`. Each skeleton's header cites
its upstream source — filling one in means replacing the no-op body with the
mechanics documented here.

Upstream paths below are repo-relative (they resolve on GitHub against the
same tree). `coding-agent` = `packages/coding-agent/src`.

---

## 0. The one design fact that shapes the catalogue

prime-agent exposes exactly **one native model tool**: `ipython`. Everything
else the model can do is a **kernel-callable**: the preloaded `rlm` module and
thirteen bundled skills, all ordinary Python functions invoked from cells
(`coding-agent/src/core/tools/index.ts` — `allToolNames = {"ipython"}`).

Therefore the port's tool list is not a list of `Brute::Tool` classes — it is
the **kernel namespace API** (`lib/prime_agent/kernel_runtime.rb` +
`kernel_agents.rb`) plus host-bridge handlers. Middleware is where every
host-side feature lives (refinement, compaction, goals, …), exactly the
pattern stages 1–5 already follow.

prime-agent's kernel↔host bridge: Python `rlm.host_request(type, payload)`
over a Jupyter comm (`host.request`); the host dispatches on `type`
(`coding-agent/src/core/agent-session.ts` `_createKernelHostHandlers`).
The port's equivalent today is the refine **request file** drained by
`Middleware::AutoRefine`; each host-bridge skill below generalizes that
pattern (request file per service, drained at turn boundaries).

---

## 1. Tools — the native tool

### T1 ✅ `ipython` → `iruby`
Persistent kernel as the only model-facing tool. Single `code` param;
`executionMode: "sequential"` (kernel is single-threaded); busy-kernel policy:
interrupt → wait-or-kill choice → `KERNEL_RESTART_NOTICE` on kill.
Tool description (upstream, port verbatim, s/Python/Ruby/):
> "Execute Python scratchpad code and `%%bash` shell cells in a persistent IPython kernel. Variables, imports, and loaded data persist across calls, and are revived on a best-effort basis when a session is resumed…"
- Refs: `coding-agent/src/core/tools/ipython.ts:143-150` (schema), `:628-634` (description)
- Port: `lib/prime_agent/iruby_tool.rb` + `kernel_manager.rb` + `kernel_provisioner.rb` — **wired (stage 1)**.

---

## 2. Tools — the kernel runtime API (`rlm` module surface)

Preloaded into every kernel namespace (`prime-agent-runtime/src/rlm/__init__.py`).
Port target for all of these: `lib/prime_agent/kernel_runtime.rb` /
`kernel_agents.rb` (loaded into IRuby by the stage-3 bootstrap).

| # | API | Semantics | Status |
|---|-----|-----------|--------|
| K1 | `rlm(prompt, name:, model:)` / `rlm.run` | Spawn recursive child; returns admission handle `{rlm_child_id, name, session_dir, model}` **immediately — never the answer**. Default name `subagent-<prompt-slug>-<id-suffix>`, max 64 chars. Depth cap: settings `rlmMaxDepth` → env `RLM_MAX_DEPTH` → default **1** | ✅ `KernelAgent.spawn` (stage 5; port cap `BRUTE_KERNEL_AGENT_MAX_DEPTH`, default 2) |
| K2 | `rlm.find_models(query="", limit=8)` | Bounded fuzzy search over the authenticated model catalog (exact < prefix < substring across `provider/id`, id, name); limit clamp ≤ **20**. Never exposes the full catalog to the prompt | 🔲 — needs M14 |
| K3 | `rlm.list_subagents()` | Parent-scoped child registry `{rlm_child_id, active_session_id, session_id, session_name, session_dir, status: running\|completed\|error}`; survives compaction/restart | ◐ `KernelAgent.finished`/handles exist; add a registry-listing call |
| K4 | `rlm.delete_subagent(target)` | Delete one retained direct child (id or name); `{subagent, outcome: "deleted"\|"skipped_running"}` | ◐ `KernelAgent.stop(name)` kills; add dispose/delete-of-record |
| K5 | `harness.*` | Full CRUD store: `create/update/delete_{memory,prompt_note,skill,subagent}`, `record_refinement`, `plan_refinement`, `overview`, `snapshot`; local scope default, `global_=True` for cross-session; skill entries validated (`reference.type == "python"`, import + callable) | ✅ stage 2/3 (`harness_store.rb` + kernel runtime) |
| K6 | `host_request(type, payload)` | Generic typed kernel→host bridge; `{status: "ok"…}` / `{status:"error"}`; payload `type` written last so it can't be rerouted | ◐ refine request-file only; generalize per-service |

Refs: `prime-agent-runtime/src/rlm/__init__.py:143-231` (spawn/list/delete),
`:166-176` (find_models), `harness.py` (entire store),
`coding-agent/src/core/rlm-runtime.ts:152-199` (host handlers, name/model
validation), `:57-59` (`RLM_SUBAGENT_SESSION_NAME_MAX_LENGTH=64`,
`DEFAULT_RLM_MODEL_SEARCH_LIMIT=8`, `MAX_RLM_MODEL_SEARCH_LIMIT=20`).

---

## 3. Tools — the 13 bundled skills (kernel-callable modules)

Bundled from `packages/coding-agent/skills/*`; pre-imported into the kernel
namespace by the bootstrap cell (`coding-agent/src/core/tools/ipython.ts:70-141`
— modules with `run()` become async-callable). "Bridge" = host_request types the
skill calls; bridge skills need the matching middleware from §4. "Kernel-pure"
skills are self-contained and are the easiest ports.

### Kernel-pure skills

| # | Skill | API | Port notes | Status |
|---|-------|-----|------------|--------|
| S1 | `edit` | `await edit(path, old_str, new_str)` — exact **single-occurrence** replacement; `~`-expand; raises on 0 or >1 matches; emits diff display MIME `application/vnd.prime-agent.diff+json` (`{path, old_str, new_str, start_line}`) | ✅ `work/.brute/skills/edit/lib/edit.rb` — `Edit.run(path:, old_str:, new_str:)`; diff display wired end-to-end (skill `display_data` → `KernelManager::Result.diffs` → `IrubyTool` +/- rendering) | ✅ |
| S2 | `websearch` | `await websearch(query, max_output=8192, timeout=45, num_results=5)` — Serper API (`POST https://google.serper.dev/search`); key from `SERPER_API_KEY` env or `auth.json` `serper`; env knobs `PRIME_AGENT_WEBSEARCH_TIMEOUT`, `PRIME_AGENT_WEBSEARCH_NUM_RESULTS`; formatted sections: knowledge graph, organic, people-also-ask; head+tail truncation with marker | ✅ `work/.brute/skills/websearch/lib/websearch.rb` — `Websearch.run(query, max_output:, timeout:, num_results:)`, net/http, key re-resolved per call | ✅ |
| S3 | `attach_image` | `await attach_image(*paths)` — loads PNG/JPEG/GIF/WebP into model context as an attachment. Caps: source ≤ 20 MB & ≤ 36 MP; attachment ≤ 350 000 b64 chars, ≤ 1200 px; JPEG quality ladder 82/72/60/48/36; transparency flattened on `#888888`; emits MIME `application/vnd.prime-agent.attachment+json` | Needs a kernel→host display channel **and** multimodal support in the message transport. Defer until a vision model is in play. Refs: `skills/attach-image/src/attach_image/attach_image.py` | 🔲 |
| S4 | `prime-intellect` | instruction-only (SKILL.md + `references/`) — how to drive the `prime` CLI (verifiers, evals, sandboxes, GPU) | Drop into `work/.brute/skills/` — works **today** via `Brute::Prompts::Skills`; no code | 🔲 (trivial) |
| S5 | `skill-creator` | instruction-only — teaches authoring markdown vs Python-backed skills, locations & precedence (explicit → project → global → package → built-in) | Same as S4; port the doc, adapt paths to `.brute/skills/` | 🔲 (trivial) |

### Host-bridge skills (thin wrappers — the middleware does the work)

| # | Skill | API | Bridge types | Needs | Status |
|---|-------|-----|--------------|-------|--------|
| S6 | `compact` | `status()` → `{tokens, context_window, percent, scheduled}`; `run(instructions=nil)` → schedules compaction **at turn end** (never mid-cell) | `compact.status`, `compact.run` | M1 | ✅ `CompactProxy` in `kernel_runtime.rb` (preloaded `compact`; request/status file pair under the local harness dir — same bridge shape as `refine`) |
| S7 | `refine` | `status()` → `{pending, in_flight}`; `run(instructions=nil, global_=false)` → schedules refinement at turn end | `refine.status`, `refine.run` | M15 | ✅ stage 3/4 (request file + `AutoRefine` + `RefineOnExit`) |
| S8 | `goal` | `get()` → `{goal, remaining_tokens, completion_budget_report}`; `create(objective, token_budget=nil)`; `complete()` | `goal.get/create/complete` | M2 | 🔲 |
| S9 | `agent_message` | `list_agents()` → `{current, entries}` (family roster); `send(message, receiver_role: parent\|sibling\|child, receiver_name:)`; broadcast: `send("all", broadcast_message)`; receipts `{deliveryStatus: delivered\|queued}`; emits MIME `…agent-message+json` | `agent_message.list_agents`, `agent_message.send` | M6 | 🔲 |
| S10 | `agent_observe` | `list_agents()`, `get_agent(target)`, `recent_messages(target, limit=8, max_chars=800)` — read-only; `limit` clamp 1–50, `max_chars` clamp 80–2000 | `agent_observe.list/get/recent` | M7 | 🔲 |
| S11 | `rlm_heartbeat` | `list(include_inactive=false)`, `create(instruction, interval="every 5m", label=nil, delivery_mode="steer")`, `update(id, …status: pause\|resume…)`, `delete(id)` — agent-owned multi-heartbeats; **cannot** touch the user heartbeat | `rlm_heartbeat.list/create/update/delete` | M4+M5 | ✅ `RlmHeartbeatProxy` in `kernel_runtime.rb` (preloaded `rlm_heartbeat`; writes the shared job store directly — no bridge needed) |
| S12 | `linear` | `McpIntegration` subclass → `await linear.<tool>(...)` auto-discovered from `https://mcp.linear.app/mcp`; fresh streamable-HTTP session per call; `NotEnabled` until OAuth | `mcp.refresh`, `mcp.config`, `mcp.begin_login` | M13 | 🔲 |
| S13 | `notion` | same shape, `https://mcp.notion.com/mcp`; hyphenated tool names called via `call_tool` | same | M13 | 🔲 |

Refs for all SKILL.md contracts: `packages/coding-agent/skills/<name>/SKILL.md`;
MCP base: `prime-agent-runtime/src/rlm/mcp_base.py` (discovery, per-call
sessions, 30 s expiry skew, `McpToolError` on `isError`).

---

## 4. Middleware — the host machinery to port

Ordering follows the brute placement rules from `examples/hermes/MIDDLEWARE.md`
(per-turn outside `Loop::ToolResult` unless noted). Each entry: **what →
mechanics → defaults → upstream refs → port target / brute counterpart**.

### Continuation machinery (fire between turns, inject `role: user`)

**M1 ✅ Compaction — threshold + overflow + requested + branch summary**
`Middleware::Compaction`. Three triggers: (a) **threshold** —
`contextTokens > contextWindow − reserveTokens`, checked at turn end;
`contextTokens` = last assistant `usage.totalTokens` + chars/4 estimate of the
tail; (b) **overflow** — provider context-overflow error ⇒ strip error, compact,
retry **once**; (c) **requested** — kernel `compact.run` or `/compact`, runs at
turn end. Cut point walks backwards to ≥ `keepRecentTokens`, never on a tool
result; splitting mid-turn adds a separate turn-prefix summary (budget
`0.5 × reserveTokens`). Summary is one `role: user` call with
`SUMMARIZATION_SYSTEM_PROMPT`; iterative `<previous-summary>` merge preserves
Done/In-Progress/Blocked/Decisions/Next Steps; injected back as a
`compactionSummary` message that flattens to `role: user` ("The conversation
history before this point was compacted…"). Cumulative `<read-files>` /
`<modified-files>` tracking (from `edit` calls). **Branch summary**: on tree
navigation, summarize the abandoned branch (maxTokens 2048, preamble "The user
explored a different conversation branch…") and inject at the target.
- Defaults: `reserveTokens` **16384**, `keepRecentTokens` **20000**, summary
  maxTokens `0.8 × reserveTokens`, compaction enabled + model-callable by default
- Refs: `core/compaction/compaction.ts:229-233,397-459,636-717`,
  `branch-summarization.ts:253-360`, `core/agent-session.ts:8008-8167`
- brute counterpart: `Middleware::CompactionCheck` (`040_compaction_check.rb`)
  exists but its compactor is **commented out** and its thresholds (100k tokens /
  200 messages) don't match — fill in with prime-agent semantics. Kernel state
  survives compaction by construction (IRuby is out-of-band), same as upstream.
- **Ported:** `lib/prime_agent/compaction.rb` (full algorithm: estimator,
  cut points, prompts in `prompts/compact_*.erb`, file tracking) +
  `middleware/compaction.rb` (three triggers, request/status file bridge,
  `BRUTE_CONTEXT_WINDOW` for the threshold). Adaptations: usage-aware
  estimation runs in estimate mode (brute's transport carries no per-message
  usage — upstream's post-compaction state is identical); file tracking reads
  the edit skill's diff displays on tool results (upstream scans native-edit
  tool calls — same effective coverage); branch summary waits on M9 (its
  trigger doesn't exist yet).

**M2 🔲 Goals — the persistent thread goal**
`Middleware::Goal`. Durable objective re-injected after **every** assistant turn
until `goal.complete()`. State machine `idle → active → paused | budget_limited |
complete | error`; continuation message is `<goal_context>…</goal_context>`
(status, tokens used, budget remaining, anti-premature-completion instructions;
objective XML-escaped as untrusted data) flattened to `role: user`; runs
**before** autonomous continuation. Token budget counts `input + output` only
(cache excluded), wall-clock separately; budget hit ⇒ `budget_limited` + a
wrap-up steer ("Do not start new substantive work…"). Objective edits inject an
`objective_updated` variant. Persisted as a session entry; max objective
**4000 chars**; creating a goal force-activates the kernel tool so the model can
reach `goal.complete()`. Feeds S8.
- Refs: `core/goals.ts:154-286`, `core/agent-session.ts:3167-3196,2112-2181`
- brute counterpart: none. Continuation hook = same shape as `AutoRefine`'s
  turn-boundary drain.

**M3 🔲 Autonomous mode — bounded continuations + quality gates**
`Middleware::Autonomous`. When enabled, after each turn decides whether to
inject a continuation: never after error/abort; runs gate shell commands (exit 0
= pass); **skips re-running a failed gate when the git worktree snapshot is
unchanged** (status + diff + sha256 of untracked, excluding `verification/`,
`target/`, `Cargo.lock`, …). Gate failure injects "Autonomous quality gate
failed (attempt N/M): `<cmd>` … Continue working." Token accounting excludes
cache reads. Limits stop the run with a surfaced reason.
- Defaults: `maxContinuations` **3**, `maxTurns` **12**, `maxTokens` **80 000**,
  `timeoutMs` **30 min**; gates: `maxRetries` **3**, `timeoutMs` **5 min**,
  output cap **6000 chars**; RLM children force-disabled
- Refs: `core/autonomous.ts:45-64,196-348,374-469`
- brute counterpart: `Brute::Prompts::Autonomy` is prompt-text only; the
  continuation loop is new. CLI/`/autonomous` toggles are driver concerns.

**M4 ✅ Cron store & scheduler**
`Middleware::CronSchedule` + a store class. JSON job store shared by cron,
user heartbeat, and rlm_heartbeat (`source: "cron"|"heartbeat"|"rlm_heartbeat"`);
atomic writes (tmp+fsync+rename, 0600) with cross-process lock; `claimDue`
appends a dispatch record and **advances `nextRunAt` before running** — missed
ticks coalesce to exactly one dispatch; in-flight duplicate ⇒ skip +
`lastSkippedAt`; crash recovery stamps `"Interrupted before scheduled operation
completion"`; per-session dispatch lanes. Schedule syntaxes: `in 30m`,
`every 5m`, `at <ISO>`, 5-field cron + `@hourly/@daily/@weekly/@monthly`;
**min recurring interval 10 s**; default schedule `every 5m`.
- Refs: `core/cron-jobs.ts:977-1139,1574-1655` (store), `:202-216` (per-session
  artifacts `session-artifacts/<id>/scheduled-jobs.json`)
- **Ported:** `lib/prime_agent/cron_store.rb` (store + claim ledger + parser;
  bare `"5m"` interval shorthand added for the skill API) +
  `lib/prime_agent/schedule_driver.rb` (the scheduler). **Model change:**
  there is no resident session, so delivery = a fresh agent run per due job
  (the systemd timer provides the outer cadence; `BRUTE_FOLLOW=1` loops
  in-process). Per-session dispatch lanes are subsumed: runs are sequential.

**M5 ✅ Heartbeats — user singleton + agent multi**
`Middleware::Heartbeat` on the M4 store. User heartbeat: **one per session**
(create cancels prior), recurring only, `status/pause/resume/clear`, inherits
previous delivery mode. rlm_heartbeat: many per session, **no numeric cap**.
Delivery: `steer` (default; interrupt at next turn boundary) vs `follow_up`
(wait for idle); **defer tick** while session is compacting/retrying/bash-busy/
has pending work (follow_up also defers while streaming); ticks coalesce via
queue key `heartbeat:<job.id>`; injected message is custom type
`heartbeat_prompt` flattened to `role: user`, `resumeIfIdle: true`; a paused/
updated heartbeat drops its queued follow-up. Feeds S11.
- Refs: `core/cron-jobs.ts:318-500,1347-1372`, `core/agent-session.ts:4516-4523`,
  `core/messages.ts:401-420`
- **Ported:** singleton user heartbeat (`create_heartbeat` cancels the prior;
  seeded from `BRUTE_HEARTBEAT`/`BRUTE_HEARTBEAT_EVERY` in this no-TUI port)
  and multi agent heartbeats via the preloaded `rlm_heartbeat` proxy (S11).
  **Model change:** delivery modes/deferral/queue coalescing are
  resident-session concepts and drop away — every delivery is effectively
  follow_up (a due job becomes its own run between runs). `delivery_mode` is
  stored as metadata only. A mid-run steer, if ever wanted, is when a thin
  turn-boundary drain middleware earns its place.

**M6 🔲 Agent messages — family bus**
`Middleware::AgentMessages` (or a service owned by the driver). "Nuclear family"
roster only: parent, siblings (same depth+parent), direct children; name
uniqueness per (depth, parent) scope. Send resolves exactly one roster match;
**delivery is always steer** (the `auto/steer/follow_up` input is legacy-ignored);
busy target ⇒ queue + receipt `queued` (never await — mutual sends must not
deadlock), idle ⇒ `delivered`. Injected message: custom type `agent_message`
("[from <relationship>[:<name>]] … Message id: agentmsg_<uuid>") flattened to
`role: user`. Broadcast `send("all", msg)` fans out with per-target receipts —
kernel-side only, direct sends reject `all/*/broadcast`.
- Limits: message **16 384 chars**; pending **20/session**; rate limit token
  bucket **3 tokens / 1000 ms** per sender→target pair (refunded on failure)
- Refs: `core/agent-messages.ts:12-15,216-250,334-523`
- Port note: KernelAgents share one kernel process — the roster/mailbox can be
  far simpler (in-process handles + turn-boundary drain), but keep the receipt,
  limits, and roster semantics identical. Feeds S9.

**M7 🔲 Agent observe — read-only family inspection**
`Middleware::AgentObserve`. `list` → summaries with computed status
(`tool|model|compacting|busy|user|idle`), `messageCount`, latest-message preview
**truncated to 240 chars**; `get(target)` one agent; `recent(target, limit,
max_chars)` last-N previews `{index, role, timestamp, text, truncated,
toolCalls, customType}` — `limit` default **8** clamp 1–50, `max_chars` default
**800** clamp 80–2000; images render as `[image]`. Family-reach enforced; never
mutates. Feeds S10.
- Refs: `core/agent-observe.ts:92-200`

**M8 🔲 Side question (`/btw`)**
Throwaway **cloned agent** over `structuredClone(messages)` + replayed prior
side turns; `tools: []`, `thinkingLevel: "off"`, `shouldStopAfterTurn: → true`
(exactly one turn). Question wrapped `<side_question>…</side_question>`; first
turn prepends the instruction ("Answer using only the conversation context…
none of this side conversation is added to the main session"); each follow-up
re-clones the live main context. Nothing persisted.
- Refs: `core/side-question.ts:24-158`
- Port note: trivial with `Brute.agent` — build a one-shot pipeline over a
  message copy. Driver-level command, not model-facing.

**M9 🔲 Session tree — fork / clone / navigate + branch summary**
In-file branching via parent-linked entries (navigate stays in the same file;
`/fork` creates a new file); usage sums are fork-aware. Abandoned-branch summary
(M1) is the only model-visible piece. brute counterpart: `Middleware::Checkpoint`
(`008_checkpoint.rb`) is the closest existing hook.
- Refs: `core/context-tree.ts:60-324` (usage tree), `core/agent-session.ts:10687-10933`
- Priority: low for one-shot/scheduled runs; defer.

### Turn-pipeline policy

**M10 🔲 Prompt queue — steer vs follow-up lanes + admission**
Two lanes: `next_turn_boundary` (steer — sets a stop-pending flag, current run
ends at the boundary, queued message heads the new turn) and `when_run_idle`
(followUp). Busy admission without an explicit behavior **throws**; duplicate
follow-ups with the same `queueKey` coalesce; pump gates on activity (no
compaction/retry/bash/refine-apply in flight).
- Refs: `core/agent-session.ts:5095-5484`, `core/session-action-store.ts:424-435`
- brute counterpart: `Middleware::UserQueue` (trivial FIFO) — extend with lanes,
  queue keys, and the busy-throw. Hermes invariant applies here too: nothing
  splices a user message mid-loop; steering = new turn at the boundary.

**M11 ✅ Tool-result truncation**
Kernel cell cap `DEFAULT_MAX_OUTPUT_CHARS` **65536** with suffix
`[... output truncated at N chars ...]`; shared tool truncation
`DEFAULT_MAX_LINES` **2000** / `DEFAULT_MAX_BYTES` **50 KB**, UTF-8 safe, never
partial lines (except single over-long tail line); grep line clip 500.
- Refs: `core/tools/truncate.ts:11-13`, `core/kernel/index.ts:31`
- **Ported:** `lib/prime_agent/truncate.rb` (truncate.ts verbatim: head/tail/
  line, UTF-8 edge, result metadata) + `middleware/result_caps.rb`
  (tail-truncates tool results at 2000 lines/50 KB with a kept-of-total
  notice; first cap to fire wins — kernel notice and brute's net pass
  through). Cell cap: `KernelManager::Output` (stage 1).

**M12 ✅ File mutation queue (per-tool-call)**
Serializes mutations targeting the same file (realpath key), parallel across
different files. Refs: `core/tools/file-mutation-queue.ts:6-39`.
- **Ported kernel-side:** `Edit::MutationQueue` in the edit skill
  (realpath-canonical keys, waiter-counted self-cleaning map) — mutations in
  this port happen inside the kernel, not the tool pipeline, so the queue
  lives where the mutations are. Host-side file tools remain covered by
  brute's `lib/brute/tools/fs/file_mutation_queue.rb`. The pass-through
  middleware scaffold was retired (no tool-pipeline work existed for it).

**M13 🔲 MCP manager — OAuth + catalog + kernel bridge**
Built-in catalog (`linear`, `notion`; both OAuth HTTP) overlaid by user
`mcpServers` (http managed host-side, stdio self-manages in-kernel). OAuth 2.1:
discovery → RFC 7591 dynamic registration → PKCE S256 → localhost callback
(default port **53700**, 10 candidates) or manual paste; token store with
refresh, `expires − 30 s` kernel-side skew; override of a catalog URL without
OAuth **unregisters** the built-in provider (no token leak). Unauthed servers
hide their skills from the prompt. Bridge: `mcp.refresh` (refresh + rewrite
auth.json under lock), `mcp.config` (host-authorized URL/headers),
`mcp.begin_login`. Feeds S12/S13.
- Refs: `core/mcp/mcp-manager.ts:62-204`, `packages/ai/src/mcp/oauth.ts`,
  `prime-agent-runtime/src/rlm/mcp_base.py`
- Priority: defer (external-service integration); scaffold with
  `NotEnabled`-raising stubs so S12/S13 import cleanly.

**M14 🔲 Model registry & `find_models`**
Authenticated catalog + fuzzy scoring (exact < prefix < substring over
`provider/id`, id, name) for the `rlm(…, model:)` override (K2); selector is
exact `provider/model`. Refs: `core/rlm-runtime.ts:122-149`.
Port: OpenRouter model list + the same scoring; also feeds `/model` UX later.

### Prompt & session infrastructure

**M15 ✅ Refinement (`/refine` + auto)**
Review-gate → JSON edits → validated apply with snapshots → rollback; kernel
`refine.run` drains at turn boundaries; auto every `BRUTE_REFINE_TURNS`
(default 25); exit distill (`BRUTE_REFINE_FINAL=0` disables).
Wired: `refinement.rb`, `refiner.rb`, `Middleware::AutoRefine`,
`Middleware::RefineOnExit` (stages 3–4).
Upstream: `core/refinement/refinement.ts` (1017 lines; prompt-overview caps
`DEFAULT_OVERVIEW_ENTRY_LIMIT=6`, `REFINEMENT_LIMIT=5`, `CONTENT_LIMIT=180`).

**M16 ◐ Skills system — discovery, prompt block, `/skill:<name>`**
Discovery: `SKILL.md` roots (frontmatter `name`/`description` required —
missing description = silently dropped; `disable-model-invocation` honored),
dirs: user `~/.prime/agent/skills`, project `.prime/agent/skills`, explicit;
Python-backed detection via `pyproject.toml` + `src/<import>/__init__.py`;
prompt block `<available_skills>` with `<name>/<type>/<python_import>/
<description>/<location>`; `/skill:<name>` expands a `<skill name location>`
block. Port: `Brute::Prompts::Skills` + `Middleware::Skills` (`025_skills.rb`)
+ `tools/skill_load.rb` already cover markdown skills — **extend** with the
XML block format and (for kernel-callable skills) a `.brute/skills/*/lib`
loader, which the stage-3 bootstrap already globs.
- Refs: `core/skills.ts:202-254,389-481`, `core/skill-blocks.ts`

**M17 🔲 Kernel snapshot/restore (session resume)**
dill-based namespace snapshot, debounced **1500 ms** after each ok execute,
max **256 MiB**, bounded final snapshot on shutdown, restore-on-boot with
unserializable objects dropped+reported. Refs: `core/kernel/index.ts:879-887,
1540-1573`, `core/kernel/state-snapshot.ts`. Port: `Marshal`/`_SESSION` dump in
`kernel_manager.rb`; needed only when sessions persist across runs — defer.

**M18 🔲 Usage accounting & context tree**
Per-node own vs total usage (subtract `child_usage_attributed` across **all**
entries — fork-aware); context utilization `estimateContextTokens` → percent
(null right after compaction). Refs: `core/context-tree.ts:81-152`.
brute counterpart: `Middleware::OtelTokenUsage` (`015_otel_token_usage.rb`);
child attribution is new (KernelAgents should attribute tokens to the parent).

**M19 ◐ System-prompt assembly & cache discipline**
Upstream rebuilds the prompt **only on discrete events** (init, tool-set
change, maxDepth change, applied refinement, extension resources) and reuses
it byte-for-byte otherwise — prompt caching is sacred; section order: RLM
prefix → subagent guidance → harness state → additional guidance → project
context → skills XML → append. The port **deliberately re-renders every turn**
(`Middleware::PromptTemplate`, stage 2) so harness writes appear mid-run.
- Refs: `core/system-prompt.ts:72-184`, `core/agent-session.ts:4276-4329`
- Action: keep the divergence **documented**; if prompt-cache cost becomes an
  issue, add dirty-tracking so the template only re-renders when a dynamic
  section changed. Section order in `prompts/system.erb` should stay aligned
  with upstream.

**M20 🔲 Orphan-process journal (driver concern)**
JSONL of detached child pids + start-time identity (never kill recycled pids);
reaper SIGKILLs the process group. Refs: `core/orphan-process-journal.ts`.
Port relevance: background `%%bash` from the kernel is the leak vector; the
systemd sandbox already contains the run. Low priority.

---

## 5. Suggested porting order (stage 6+)

Dependency-driven; each stage is scaffold-first, then fill in:

| Stage | Items | Why this order |
|-------|-------|----------------|
| 6 | S1 edit, S2 websearch, M11 caps, M12 mutation queue | Kernel-pure; zero new middleware; immediate agent capability |
| 7 | M1 compaction + S6 compact | Long runs impossible without it; brute has a dormant stub |
| 8 | M4+M5 cron/heartbeats + S11 | ✅ done — store + ScheduleDriver + kernel proxy (driver delivery model) |
| 9 | M2 goals + S8, M3 autonomous | Continuation machinery, both ride the M5 turn-boundary plumbing |
| 10 | M6+M7 messages/observe + S9+S10, K3/K4 | Upgrades KernelAgents from fire-and-forget to a real family bus |
| 11 | M13 MCP + S12/S13 stubs, M14 find_models + K2 | External integrations; scaffold raises `NotEnabled` |
| 12 | S3 attach_image, M9 tree, M17 snapshots, M18 attribution, M20 orphans | Deferred: needs vision transport / persistent sessions / daemon UX |

Trivial anytime: S4 prime-intellect, S5 skill-creator (drop-in SKILL.md files),
M16 skills-XML extension, M19 cache-discipline note.
