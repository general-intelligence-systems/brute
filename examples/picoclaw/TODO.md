# PicoClaw port — extraction list

Checkbox tracker for the port. Full mechanics/config/refs per item: `FEATURES.md`.
Source: `references/picoclaw` @ `49183d7`.

Every item below gets a **skeleton** (hermes pattern: real name/description/params, no-op body).
Groups = fill-in priority. **Scaffolded**: all P0/P1/P2 tools and P0–P2 middleware exist as
no-op files wired into `main.rb`; tick a box when the body is filled in.

## Tools — P0: core parity (no external deps, fill first)

- [x] `read_file` — `pkg/tools/fs/filesystem.go:281` — both modes (`bytes` paginated, `lines` numbered)
- [x] `write_file` — `filesystem.go:869` — overwrite guard, atomic write
- [x] `edit_file` — `fs/edit.go:19` — exact single-occurrence replace
- [x] `append_file` — `fs/edit.go:83`
- [x] `list_dir` — `filesystem.go:994`
- [x] `exec` — `pkg/tools/shell.go:139` — action mux (run/list/poll/read/write/kill/send-keys), background sessions, PTY, deny patterns (now inside the tool: full `defaultDenyPatterns` + `guardCommand` port)
- [x] `web_search` — `integration/web.go:1906` — **upgraded**: `count`+`range` params, full provider chain (sogou/ddg default; brave/tavily/kagi/gemini/perplexity/searxng/glm/baidu)
- [x] `web_fetch` — `integration/web.go:2073` — SSRF guard (pre-flight/redirect/connect-time), redirect cap, plaintext/markdown extract, CF-challenge retry
- [x] `cron` — `pkg/tools/cron.go:40` — **upgraded**: `at_seconds` one-shots, get/update/enable/disable actions, command jobs + ACL gates

## Tools — P1: subagents (need the `subturns` middleware)

- [x] `spawn` — `spawn.go:20` — async subturn, critical (joined before turn end; results injected by Drain)
- [x] `subagent` — `subagent.go:347` — sync subturn
- [x] `spawn_status` — `spawn_status.go:19` — listing (channel-scoping N/A here)
- [x] `delegate` — `delegate.go:21` — registered when agents.list is non-empty (main + ≥1); target's model/workspace, allowlist, `[Response from agent "id"]` prefix

## Tools — P1: skills registry

- [x] `find_skills` — `integration/skills_search.go:27` — clawhub+github registries, trigram cache
- [x] `install_skill` — `integration/skills_install.go:43` — into `<workspace>/skills/<slug>/`, moderation flags

## Tools — P2: channel-dependent (delivered to `outbound.jsonl`, the port's bus)

- [x] `message` — `integration/message.go:57` — outbox delivery + per-round send tracking → final-response dedup in the driver; media attachments gated by `tools.message.media_enabled`
- [x] `reaction` — `integration/reaction.go:18` — always errors (no ReactionCapable channel in this port, upstream parity)
- [x] `send_file` — `fs/send_file.go:31` — MediaStore + outbox
- [x] `send_tts` — `integration/tts_send.go:23` — registered only with a TTS model (`voice.tts_model_name` or a *tts* model)
- [x] `load_image` — `fs/load_image.go:35` — magic-byte validation + media:// ref (path tag next pass; base64 inline blocked on brute transport)

## Tools — P2: hardware (Linux SBC; default-off, ioctl via Fiddle)

- [x] `i2c` — `hardware/i2c.go:15` — SMBus ioctls; i2cdetect MODE_AUTO scan strategy
- [x] `spi` — `hardware/spi.go:15` — SPI_IOC_MESSAGE full-duplex; mode/bits/speed config
- [x] `serial` — `hardware/serial.go:51` — termios config, poll read/write, port whitelist

## Tools — P3: MCP (via the official `mcp` gem)

- [x] `mcp_tool` wrapper — `integration/mcp_tool.go:92` — name sanitization + FNV suffix, artifact spill >16k chars, media store, audience filter
- [x] `tool_search_tool_regex` — `search_tool.go:17` — promotes hidden tools (TTL 5 turns)
- [x] `tool_search_tool_bm25` — `search_tool.go:100` — BM25 engine port (k1=1.2, b=0.75)

## Context managers

- [x] legacy (default) — SessionStore + Compaction + ContextBudget + EmergencyCompression
- [x] seahorse — `pkg/seahorse/` on extralite (SQLite): schema, ingest, budget assembly, leaf/condensed compaction, FTS5 (LIKE fallback)

## Tools — seahorse (active when `context_manager: "seahorse"`)

- [x] `short_grep` — `pkg/seahorse/tool_grep.go` — FTS5/LIKE search over summaries+messages
- [x] `short_expand` — `pkg/seahorse/tool_expand.go` — full messages by id (tool_result content omitted)

## Middleware — P0: core loop parity

- [x] `heartbeat_gate` — done
- [x] `session_store` — extends brute `SessionLog`: sanitize-on-load (drop orphans/incomplete tool blocks), pre-turn restore point for aborts — `pkg/session/`, `context.go:1023-1201` (sk_v1 keys/scope dimensions are channel-scoped — land with channels)
- [x] `memory_files` — MEMORY.md + last-3-days daily notes into prompt — `pkg/agent/memory.go`
- [x] `skills_catalog` — `<skills>` XML catalog + active/forced skill bodies — `pkg/skills/loader.go`, `context.go:278-306`
- [x] `context_budget` — token estimator (chars×2/5, +256/media), proactive trim when messages+system+tools+max_tokens > window — `context_budget.go`, `pkg/tokenizer/estimator.go`
- [x] `summarize` — **extended `compaction`**: triggers msg>20 OR tokens>75% window; keep-last-4 cut; split-merge for >10 msgs; truncation fallback — `context_legacy.go:79-262`
- [x] `emergency_compression` — on context-window API error: drop oldest ~50% of turns (never split tool sequences), retry (max 2, linear backoff 2s) — `context_legacy.go:117-172`, `pipeline_llm.go:291-450`
- [x] `steering` — **extended `steering_loop`**: one-at-a-time/all modes, graceful interrupt (`interrupt` file: hint + one more pass; tool-strip delta noted), hard abort (`abort` file + session rollback), queue drain — `pkg/agent/steering.go`
- [x] `state_manager` — `state/state.json` last-channel KV (heartbeat/cron delivery target) — `pkg/state/state.go`

## Middleware — P1: per-tool-call policy (layer with WorkspaceGuard/SafetyGuard)

- [x] `tool_policy` — tools/tool_policy.rb wrapper (brute's per-call seam): schema validation (validate.go), AGENT.md `tools:` allowlist at registration, sensitive-data scrub ([FILTERED], min len 8), approval seam — `pipeline_execute.go:111-864`
- [x] `approval` — approve proc in the wrapper; `tools.require_approval` denies fail-closed + stages to `pending/approvals/` (no interactive surface)

## Middleware — P1: LLM-call policy

- [x] `fallback_chain` — ordered candidates, cooldowns (1m→5m→25m→1h; billing 5h→24h), RPM token buckets; state persisted to state/fallback_chain.json (one-shot process) — `pkg/providers/fallback.go`, `cooldown.go`, `ratelimiter.go`
- [x] `model_router` — light/heavy rule classifier (threshold 0.35) → env[:metadata][:llm_model] — `pkg/routing/`
- [x] `media_store` + `media_resolver` — `media://` lifecycle (refcounts, cleanup policies, TTL janitor), path tags; base64 inline blocked on brute transport (plain-string content) — `pkg/media/store.go`, `agent_media.go:60-149`

## Middleware — P2: advanced

- [x] `subturns` — depth/concurrency/timeout guards; Drain injects results per-iteration; end-of-turn join (one-shot process can't orphan children; token budget N/A) — `pkg/agent/subturn.go`
- [x] `hooks` — **brute `.on()` lifecycle hooks + `hooks.rb` HookManager**: 5 points (before/after_llm, before/after_tool, approve_tool) + observers; decision contract (continue/modify/respond/deny_tool/abort_turn/hard_abort); JSON-RPC stdio process hooks; fail-open interceptors / fail-closed approval; prompt-mutation revert — `pkg/agent/hooks.go`
- [x] `evolution_cold_path` — heuristic clustering + pattern merge + LLM drafts (observe/draft/apply); `evolution_log` hot path (records now carry summary/final_output) — `pkg/evolution/runtime.go`, `pattern_clusterer.go`
- [x] `runtime_events` — turn-span events + `.on()`-wired llm/tool events; `events.logging` filter config — `pkg/events/`
- [x] `turn_profile` — history/system_prompt/skills/tools gating in main.rb (`off` skips SessionStore/Compaction/prompt/skills; tools `custom` filters) — `turn_profile_policy.go`

## Not extracting

Concrete channels, gateway/WebUI, streaming publisher, ASR/TTS, typing/placeholder cosmetics,
webhooks; built-in hooks (none exist upstream); cron `tz`
(stored-but-unused upstream).
