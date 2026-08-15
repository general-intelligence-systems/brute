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

- [ ] `spawn` — `spawn.go:20` — async subturn, critical (survives parent)
- [ ] `subagent` — `subagent.go:347` — sync subturn
- [ ] `spawn_status` — `spawn_status.go:19` — channel-scoped listing
- [ ] `delegate` — `delegate.go:21` — only when ≥2 agents configured

## Tools — P1: skills registry

- [ ] `find_skills` — `integration/skills_search.go:27` — clawhub+github registries, trigram cache
- [ ] `install_skill` — `integration/skills_install.go:43` — into `<workspace>/skills/<slug>/`, moderation flags

## Tools — P2: channel-dependent (skeleton now; no-op until a message bus exists)

- [ ] `message` — `integration/message.go:57` — per-round send tracking → final-response dedup
- [ ] `reaction` — `integration/reaction.go:18`
- [ ] `send_file` — `fs/send_file.go:31` — MediaStore + `ResponseHandled`
- [ ] `send_tts` — `integration/tts_send.go:23` — only with a TTS provider
- [ ] `load_image` — `fs/load_image.go:35` — needs `media_resolver`

## Tools — P2: hardware (skeleton only; Linux SBC, default-off upstream)

- [ ] `i2c` — `hardware/i2c.go:15`
- [ ] `spi` — `hardware/spi.go:15`
- [ ] `serial` — `hardware/serial.go:51`

## Tools — P3: MCP (needs an MCP manager + hidden-tool TTL registry)

- [ ] `mcp_tool` wrapper — `integration/mcp_tool.go:92` — name sanitization, artifact spill >16k chars
- [ ] `tool_search_tool_regex` — `search_tool.go:17` — promotes hidden tools (TTL 5 turns)
- [ ] `tool_search_tool_bm25` — `search_tool.go:100`

## Tools — skip (seahorse-only)

- [ ] `short_grep` / `short_expand` — `pkg/seahorse/` — only if the seahorse context manager is ever ported

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

- [ ] `tool_policy` — schema validation, per-agent tool allowlist (AGENT.md `tools:`), sensitive-data filter (min len 8), `ResponseHandled`, async results re-enter as system-channel turns, message-tool delivery dedup — `pipeline_execute.go:111-864`
- [ ] `approval` — ApproveTool seam, fail-closed (hermes `write_approval.rb` precedent)

## Middleware — P1: LLM-call policy

- [ ] `fallback_chain` — ordered candidates, cooldowns (1m→5m→25m→1h; billing 5h→24h), RPM token buckets — `pkg/providers/fallback.go`, `cooldown.go`, `ratelimiter.go`
- [ ] `model_router` — light/heavy rule classifier (threshold 0.35) — `pkg/routing/`
- [ ] `media_store` + `media_resolver` — `media://` lifecycle, path tags, current-turn base64 inlining after the tool block — `pkg/media/store.go`, `agent_media.go:60-149`

## Middleware — P2: advanced

- [ ] `subturns` — depth 3 / concurrency 5 / 5-min timeout / token budget; pendingResults injection as `[SubTurn Result]` messages — `pkg/agent/subturn.go`
- [ ] `hooks` — BeforeLLM/AfterLLM/BeforeTool/AfterTool/ApproveTool + observer; JSON-RPC process transport; no built-ins upstream — `pkg/agent/hooks.go`
- [ ] `evolution_cold_path` — clustering + skill drafts (observe/draft/apply); `evolution_log` hot path already done — `pkg/evolution/runtime.go`
- [ ] `runtime_events` — event bus + `agent.*` logging subscriber — `pkg/events/`
- [ ] `turn_profile` — history/system_prompt/skills/tools gating per turn — `turn_profile_policy.go`

## Not extracting

Concrete channels, gateway/WebUI, streaming publisher, ASR/TTS, typing/placeholder cosmetics,
webhooks; seahorse context manager (initially); built-in hooks (none exist upstream); cron `tz`
(stored-but-unused upstream).
