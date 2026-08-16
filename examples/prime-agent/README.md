# prime-agent

[PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent)
ported to brute. The port is built up stage by stage — every feature is a
middleware:

- **stage 1 — the persistent kernel** (wired): prime-agent's single
  model-facing tool is an IPython kernel; here it is an **IRuby** kernel
  (Ruby speaking the Jupyter protocol over ZeroMQ, via the pure-Ruby
  [omq](https://github.com/zeromq/omq.rb) transport). `lib/prime_agent/` —
  `jupyter.rb` (wire framing), `kernel_manager.rb` (spawn + drive iruby),
  `kernel_provisioner.rb` (lazy boot), `iruby_tool.rb` (the tool),
  `middleware/kernel_lifecycle.rb` (shutdown). Ruby state persists across
  tool calls; the kernel is the only tool, so everything the agent does is
  programmatic.
- **stage 2 — continual harness in the prompt** (wired): the self-learning
  state ledger. `harness_store.rb` is an exact port of prime-agent's
  `harness_state.json` store (entries: `prompt` notes, `memory`, `skill`,
  `subagent` specs; local + global scope; atomic dual-writer file access).
  All prompt text lives in `prompts/*.erb`: the system prompt is
  `prompts/system.erb`, driven by a `Brute::PromptTemplate` whose dynamic
  sections (`cwd`, `harness_state`, `skills`) are procs;
  `middleware/prompt_template.rb` re-renders it every turn, so harness
  writes and new skills appear mid-run and the template hot-reloads from
  disk. prime-agent's original prompt text is kept verbatim under
  `prompts/upstream/`. Local state lives in `<cwd>/.brute/harness/`, global
  in `~/.brute/harness/` (override: `BRUTE_GLOBAL_HARNESS_DIR`).
- **stage 3 — the self-learning loop** (wired): the bootstrap cell loads
  `kernel_runtime.rb` into the kernel, so the model can call
  `harness.create_memory(...)`, `harness.create_skill(...)`, `harness.overview()`
  etc. directly in IRuby (both sides share `harness_state.json` via atomic
  writes + mtime re-sync — prime-agent's dual-writer design). `refine.run(...)`
  in the kernel writes a request file; `middleware/auto_refine.rb` drains it at
  the next turn boundary and runs the `/refine` pass (review prompt → JSON
  edits → validated apply with before/after snapshots → rollback-able) ported
  in `refinement.rb`/`refiner.rb`. Auto-refine fires every
  `BRUTE_REFINE_TURNS` turns (default 25) behind prime-agent's review gate.
- **stage 4 — distill on exit** (wired): `middleware/refine_on_exit.rb` runs
  a final refinement pass when the run ends (a pending kernel `refine.run`
  request wins over the generic distillation), so one-shot and scheduled
  runs learn across runs. Disable with `BRUTE_REFINE_FINAL=0`.
- **stage 5 — KernelAgents** (wired): prime-agent's `rlm(...)` recursion,
  ported as agents that run *inside* the kernel. The kernel is just Ruby, so
  a KernelAgent is a real `Brute.agent` pipeline (system prompt, tool loop,
  an `iruby` eval tool bound to its own binding, OpenRouter completion) on a
  thread in the kernel process. `KernelAgent.spawn("task", name: "x")`
  returns a handle immediately (admission, never completion); the model ends
  its turn and later reads `KernelAgent.finished` → `handle.result`, or fans
  in via files. Recursion depth is capped by `BRUTE_KERNEL_AGENT_MAX_DEPTH`
  (default 2). Harness CRUD and `refine.run` work inside children, so
  delegated work feeds the same self-learning loop.
- **stage 6 — kernel-pure skills + tool caps** (wired): the `edit` skill
  (`Edit.run` — exact single-occurrence replacement, per-file mutation
  queue, and a diff display streamed over `display_data` onto the cell
  result, rendered into the tool result) and the `websearch` skill
  (`Websearch.run` — Serper, key re-resolved per call), both in
  `work/.brute/skills/`; `Middleware::ResultCaps` tail-truncates tool
  results at prime-agent's 2000-line / 50 KB caps
  (`lib/prime_agent/truncate.rb` ports truncate.ts).
- **stage 7 — compaction** (wired): `lib/prime_agent/compaction.rb` ports
  the full upstream algorithm (chars/4 estimator, cut-point selection never
  on tool results, summarize/update/turn-prefix prompts in
  `prompts/compact_*.erb`, cumulative `<modified-files>` tracking fed by
  edit's diff displays). `Middleware::Compaction` drives all three triggers:
  threshold (needs `BRUTE_CONTEXT_WINDOW`), provider-overflow compact-retry
  (once), and kernel-requested via `compact.run(...)` — the kernel's
  `compact` proxy rides a request/status file pair under the local harness
  dir, drained at the turn boundary (`compact.status` reads the published
  usage). 
- **stage 8 — scheduled prompts + heartbeats** (wired):
  `lib/prime_agent/cron_store.rb` ports the job store (atomic writes +
  flock, claim-ledger with missed-tick coalescing and crash recovery,
  `in`/`every`/`at`/cron schedules). There is no resident session to steer
  into, so `lib/prime_agent/schedule_driver.rb` delivers a due job as a
  **fresh agent run** whose task is the job's prompt — one-shot mode drains
  what's due after the initial task (this is what the systemd timer
  activates), `BRUTE_FOLLOW=1` keeps looping while future ticks exist. The
  kernel's preloaded `rlm_heartbeat` proxy (create/list/update/delete)
  writes the same store directly; the user heartbeat is a per-store
  singleton seeded from `BRUTE_HEARTBEAT`.
- **stage 9 — goals + autonomous mode** (wired): `Middleware::Goal`
  re-prompts with the `<goal_context>` user message after every turn while a
  goal is active (`lib/prime_agent/goal.rb` ports the state machine and the
  verbatim prompts; state in `goal.json`, seeded with `BRUTE_GOAL`), and the
  kernel's preloaded `goal` proxy (`get`/`create`/`complete`) drives it via
  a request file. `Middleware::Autonomous` (`lib/prime_agent/autonomous.rb`)
  adds bounded continuations with quality gates: shell gates with retries,
  git-worktree snapshots that skip re-running an unchanged failed gate, and
  continuation/turn/token/wall-clock limits. The goal gets first refusal
  every turn; autonomous defers while one is active.
- **stage 10 — the family bus** (wired): `lib/prime_agent/agent_family.rb`
  ports the roster (parent/siblings/children), validation, prompt text,
  receipts, and rate limits; `Middleware::AgentMessages` delivers mailbox
  messages as user messages at each turn boundary (shared by the root run
  and every KernelAgent child pipeline); `Middleware::AgentObserve`
  publishes each agent's transcript for the read-only `agent_observe` proxy.
  The kernel gains preloaded `agent_message` and `agent_observe` proxies,
  and `KernelAgent.list_subagents`/`delete` complete the registry surface
  (K3/K4). Also landed: the upstream-shaped `<available_skills>` block
  (`lib/prime_agent/skills_block.rb`, M16), the `prime-intellect` (verbatim)
  and `skill-creator` (adapted) doc skills (S4/S5), and M10's queue semantics
  folded into the driver model.
- **stage 11 — MCP integrations + model registry** (wired):
  `lib/prime_agent/mcp.rb` ports mcp_base.py onto the official `mcp` gem
  client (streamable HTTP): shared `~/.prime/agent/auth.json` credentials
  (env-bearer > api_key > oauth-with-skew), kernel-side token refresh under
  flock, structuredContent-first result parsing, `NotEnabled` guidance. The
  `linear`/`notion` skills wrap it (`Linear.list_tools`/`call_tool`). OAuth
  2.1 login runs host-side via `mcp_login.rb <server>` (PKCE, RFC 7591
  registration, localhost callback racing a manual paste).
  `lib/prime_agent/model_registry.rb` backs `KernelAgent.find_models` with
  the OpenRouter catalog and prime-agent's exact fuzzy scoring.
- **stage 12 — the deferred substrate** (wired): usage accounting
  (`Middleware::UsageAttribution` + a brute-side patch recording provider
  usage into env metadata; goal/autonomous/compaction now prefer real
  numbers), kernel snapshots (`KernelProvisioner` flushes a Marshalled
  namespace on a debounce and at shutdown; the next boot restores it via
  codegen — `BRUTE_KERNEL_SNAPSHOT=0` disables), the `attach-image` skill +
  `Middleware::AttachImages` (multimodal delivery into the same turn),
  session tree (`Middleware::SessionTree` journals every run;
  `BRUTE_FORK=<log>#<entry>` forks with a branch summary), side questions
  (`BRUTE_BTW`), and the orphan reaper (kernel spawn journal +
  `Middleware::OrphanReaper`).

Knobs: `BRUTE_MODEL` (model override), `BRUTE_REFINE_TURNS` (auto-refine
turn interval, default 25), `BRUTE_REFINE_FINAL=0` (skip the exit distill),
`BRUTE_GLOBAL_HARNESS_DIR` (global store location, default
`~/.brute/harness`), `BRUTE_KERNEL_AGENT_MAX_DEPTH` (recursion cap,
default 2), `BRUTE_CONTEXT_WINDOW` (model context size in tokens; enables
threshold compaction — overflow and `compact.run` work regardless),
`BRUTE_HEARTBEAT` + `BRUTE_HEARTBEAT_EVERY` (the user heartbeat instruction
and its interval, default `every 5m`), `BRUTE_FOLLOW=1` (keep running due
scheduled jobs after the initial task instead of exiting),
`BRUTE_GOAL` + `BRUTE_GOAL_TOKEN_BUDGET` (the persistent thread goal),
`BRUTE_AUTONOMOUS=1` + `BRUTE_AUTONOMOUS_GATES` (single gate command or JSON
array; plus `BRUTE_AUTONOMOUS_MAX_CONTINUATIONS`/`MAX_TURNS`/`MAX_TOKENS`/
`TIMEOUT_MS` overrides), `BRUTE_KERNEL_SNAPSHOT=0` (disable kernel namespace
snapshots), `BRUTE_FORK=<session-log>[#<entry-id>]` (fork a new run from a
prior one, with the abandoned branch's summary injected),
`BRUTE_BTW=<question>` (a side question against the finished run),
`BRUTE_MODELS_URL` (model-catalog override).

Everything not yet wired is catalogued in **FEATURES.md** — the complete list
of tools (the kernel API + the 13 bundled skills) and middleware (compaction,
goals, autonomous, cron/heartbeats, agent messaging, …) to port, with upstream
source refs, exact defaults, and a suggested stage order. prime-agent's
original prompt blocks are kept verbatim under `prompts/upstream/` as the
annotated porting source for the prompt side.

Requires `OPENROUTER_API_KEY` (override the model with `BRUTE_MODEL`).

## Run once

Copies `work/*` into the current directory (a starter `.brute/skills/`) and
runs `main.rb` with the current directory as working directory:

```
nix run ./examples/prime-agent                       # from the brute repo root
nix run ./examples/prime-agent -- --overwrite        # replace existing work/* copies
nix run ./examples prime-agent                       # via the examples dispatcher
nix run ./examples/prime-agent -- "fix the failing test"   # custom task
```

## Scheduled operation

Install (or update — re-running is idempotent) a systemd timer that runs the
agent as a dynamic user, sandboxed, with only `<dir>` writable:

```
nix run ./examples/prime-agent#schedule <dir>
```

Cadence via `PRIME_AGENT_SCHEDULE` (default `hourly`, any `OnCalendar`
expression):

```
PRIME_AGENT_SCHEDULE=daily nix run ./examples/prime-agent#schedule <dir>
```

Manage:

```
systemctl list-timers prime-agent.timer            # next activation
journalctl -u prime-agent.service                  # logs
systemd-analyze security prime-agent.service       # sandbox score
sudo systemctl stop prime-agent.timer prime-agent.service   # remove
```

The timer is transient: it does not survive a reboot — re-run the schedule
command to reinstall.

## Development

```
cd examples/prime-agent
nix develop          # shell with the bundled gems + bundix + libzmq
bundix -l            # regenerate Gemfile.lock + gemset.nix after Gemfile changes
ruby main.rb "task"  # run directly, without the runner
ruby test/integration.rb   # boot a real IRuby kernel and exercise the manager
```

Unit specs live in `__END__` blocks under `lib/prime_agent/` and run with the
repo suite: `nix develop --command bin/test` from the brute repo root.
