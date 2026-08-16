# picoclaw-clone

An autonomous-agent port of [PicoClaw](https://github.com/sipeed/picoclaw)'s
core, built on the [brute](https://github.com/general-intelligence-systems/brute)
agent framework with OpenRouter. No chat UI, no channels: an external systemd
timer wakes the agent for one **heartbeat turn** at a time; continuity lives
in the workspace files. Reference Go source: `references/picoclaw` (repo root);
complete port catalogue: `FEATURES.md`.

## Feature map

| PicoClaw (Go) | picoclaw-clone (Ruby) |
| --- | --- |
| heartbeat ticker in the gateway | the flake's systemd timer; one turn per tick |
| `HEARTBEAT.md` + skip-if-empty + `HEARTBEAT_OK` | `HeartbeatGate` middleware (same marker logic, same prompt, zero API spend when empty) |
| cron service (`at`/`every`/`expr`, `cron/jobs.json`) | `CronSchedule` middleware + `cron` tool (full action set incl. `update`, `at_seconds`, command jobs executed via `exec`; expressions via fugit); due jobs injected into the heartbeat turn |
| sessions (`*.jsonl` + meta) | `SessionStore` middleware: `sessions/<name>.jsonl`, sanitize-on-load (drops system/orphaned/incomplete tool blocks), pre-turn restore point for hard aborts |
| context compression at turn boundaries | `Compaction` (msg>20 OR tokens>75% window triggers, keep-last-4, split-merge, truncation fallback) + `ContextBudget` (proactive estimate/trim) + `EmergencyCompression` (context-error → drop oldest 50% of turns → retry, max 2, 2s linear backoff) |
| `memory/MEMORY.md` long-term memory | `MemoryFiles` middleware: MEMORY.md + last-3-days daily notes injected each turn; the agent updates them with write_file/edit_file |
| skills (`SKILL.md`) | `SkillsCatalog` middleware: workspace > ~/.picoclaw > `.brute/skills` roots, `<skills>` XML catalog in the prompt, bodies read via `read_file`, AGENT.md/AGENTS.md `skills:` frontmatter inlines bodies |
| self-evolution, observe mode | `EvolutionLog` middleware: one learning record per turn in `.evolution/records.jsonl` |
| steering (inject messages mid-run) | `SteeringLoop` middleware: drains `steer.jsonl` between tool batches (one-at-a-time/all modes), `interrupt` file = graceful stop after one pass, `abort` file = hard abort + session rollback |
| `restrict_to_workspace` sandbox | inside the six fs/exec tools (port of the `os.Root` sandbox + allow-paths regexes); `WorkspaceGuard` still wraps the brute stand-ins |
| exec deny patterns | inside `exec` (full `defaultDenyPatterns` + `guardCommand` port: deny always wins, traversal/path-token checks) |
| `web_search` (DuckDuckGo fallback) | `web_search` tool: full provider chain (sogou/duckduckgo default, brave/tavily/kagi/gemini/perplexity/searxng/glm/baidu by config), `count`/`range` filters, key rotation |
| `web_fetch` | `web_fetch` tool: SSRF guard, ≤5 redirects, 10MB cap, plaintext/markdown extraction, Cloudflare-challenge retry |
| model fallback chain + cooldowns + RPM | `FallbackChain` middleware (state/fallback_chain.json persistence; single candidate → plain call) |
| light/heavy model routing | `ModelRouter` middleware (rule classifier, threshold 0.35, routing.light_model) |
| media store (`media://` refs) | `Media` middleware (refcounted store, TTL janitor, path-tag resolver; base64 inline needs transport support) |
| subagents (spawn/subagent/spawn_status) | `Subturns` middleware + the three tools (ephemeral child turns; no recursive spawning) |
| tool arg validation + sensitive-data filter | `ToolPolicy` wrapper (validate.go port; `[FILTERED]` scrub; `tools.require_approval` staging) |
| last-channel state (`state/state.json`) | `StateManager` middleware (cli/direct in this port) |
| system prompt from workspace files | `Brute::PromptTemplate` + `prompt.erb`, re-read every turn (mtime hot-reload) |
| hooks (BeforeLLM/AfterLLM/BeforeTool/AfterTool/ApproveTool, JSON-RPC process hooks) | brute `.on()` lifecycle hooks + `hooks.rb` HookManager (decision contract, fail-open interceptors / fail-closed approval, prompt-mutation revert) |
| channels, gateway, WebUI, MCP | not ported (interactive surface) |

## Layout

```
main.rb                  # config, wiring, runner
prompt.erb               # system prompt template (Brute::PromptTemplate)
cron.rb                  # CronStore (cron/jobs.json)
hooks.rb                 # HookManager (built on brute's .on() lifecycle hooks)
FEATURES.md              # complete upstream catalogue (tools + middleware, source refs)
TODO.md                  # extraction tracker
middleware/
  heartbeat_gate.rb      # skip-if-empty + heartbeat prompt
  evolution_log.rb       # learning records
  cron_schedule.rb       # due-job firing (message inject / command exec) + persistence
  compaction.rb          # summarize old turns into the summary sidecar (upstream triggers)
  steering_loop.rb       # steer.jsonl drain + interrupt/abort files + turn loop
  runtime_events.rb      # scaffold (no-op) — event bus
  state_manager.rb       # state/state.json last-channel KV
  session_store.rb       # sanitize-on-load + restore point + JSONL persistence
  skills_catalog.rb      # <skills> XML catalog + active bodies
  memory_files.rb        # MEMORY.md + daily notes
  system_prompt.rb       # scaffold (no-op) — parts/layers/slots prompt assembly
  token_estimator.rb     # chars×2/5 +256/media estimator (shared)
  context_budget.rb      # token estimate + proactive force-compress/trim
  emergency_compression.rb # context-error → compress + retry (wraps the LLM call)
  model_router.rb        # light/heavy turn classifier → llm_model override
  media.rb               # media:// store (refcounts, janitor) + path-tag resolver
  fallback_chain.rb      # candidates/cooldowns/RPM (state/fallback_chain.json)
  subturns.rb            # registry + spawn machinery + per-iteration result drain
tools/
  tool_wrapper.rb        # guard base class
  workspace_guard.rb     # restrict_to_workspace (for stand-ins/scaffolds)
  fs_sandbox.rb          # HostFs/SandboxFs/WhitelistFs + atomic write + path validation
  diff_result.rb         # unified-diff result contract for edit_file
  exec_session.rb        # background process sessions (1MB buffer, keymaps)
  web_http.rb            # safe HTTP client (SSRF guard, redirects, caps, proxy)
  html_markdown.rb       # HTML→markdown converter
  web_search.rb          # 10-provider search chain + resolution
  web_fetch.rb           # SSRF-guarded fetch + extractors
  cron_tool.rb           # agent-facing job management (full action set)
  tool_policy.rb         # per-call wrapper: schema validation + approval + [FILTERED] scrub
  skill_registries.rb    # clawhub + github clients, search cache, zip extract
  find_skills.rb         # registry search (cached)
  install_skill.rb       # install into workspace/skills (moderation, origin meta)
  spawn.rb subagent.rb spawn_status.rb   # subturn tools (async/sync/status)
  read_file.rb           # ported (bytes + lines modes, pagination, sandbox)
  write_file.rb          # ported (overwrite guard, atomic write)
  edit_file.rb           # ported (single-occurrence replace, diff result)
  append_file.rb         # ported
  list_dir.rb            # ported (DIR/FILE, lstat semantics)
  exec.rb                # ported (7 actions, deny patterns, guard, sessions, PTY)
  load_image.rb          # scaffold (no-op)
test/                    # plain-ruby harnesses: tools_test + p0_test + p1_test + hooks_test (nix develop)
work/                    # workspace template (copied into the CWD on run)
```

## Develop

The following command replaces bundle install after updating the `Gemfile`.

```
bundix -l
```

## Run once

Copies `work/*` into the current directory and runs `main.rb` from the nix
store with the current directory as working directory:

```
nix run git+https://git.kremlin.email/n-at-han-k/agents picoclaw-clone
nix run git+https://git.kremlin.email/n-at-han-k/agents picoclaw-clone -- --overwrite
```

A bare run executes one heartbeat turn: read `HEARTBEAT.md`, inject due
cron jobs, drain `steer.jsonl`, act, persist. With no tasks and no due jobs
the run costs nothing (no API call). Positional args are a dev/test driver
(`nix run ./picoclaw-clone -- "do something"`) that bypasses the gate and
uses a separate `sessions/dev.jsonl`.

## Scheduled operation

Install (or update — re-running is idempotent) a systemd timer that runs the
agent as a dynamic user, sandboxed, with only `<dir>` writable:

```
nix run git+https://git.kremlin.email/n-at-han-k/agents#schedule picoclaw-clone <dir>
```

Cadence via `PICOCLAW_CLONE_SCHEDULE` (default `hourly`, any `OnCalendar`
expression):

```
PICOCLAW_CLONE_SCHEDULE='*-*-* *:*:00' nix run git+https://git.kremlin.email/n-at-han-k/agents#schedule picoclaw-clone <dir>
PICOCLAW_CLONE_SCHEDULE=daily nix run git+https://git.kremlin.email/n-at-han-k/agents#schedule picoclaw-clone <dir>
```

Manage:

```
systemctl list-timers picoclaw-clone.timer          # next activation
journalctl -u picoclaw-clone.service                # logs
systemd-analyze security picoclaw-clone.service     # sandbox score
sudo systemctl stop picoclaw-clone.timer picoclaw-clone.service    # remove
```

The timer is transient: it does not survive a reboot — re-run the schedule
command to reinstall.

## Local checkout

```
nix run . picoclaw-clone                   # from repo root
nix run .#schedule picoclaw-clone <dir>
nix run ./picoclaw-clone                   # or via the subflake
nix run ./picoclaw-clone#schedule <dir>
```

## Dependencies

Needs a brute release that includes `Brute::PromptTemplate`
(`lib/brute/prompt_template.rb`). Until then, run from a checkout with the
local lib shadowing the gem:

```
nix develop ./picoclaw-clone -c ruby -I~/brute/brute/lib ./picoclaw-clone/main.rb
```
