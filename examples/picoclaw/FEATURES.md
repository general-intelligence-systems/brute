# PicoClaw → brute — Complete Tool & Middleware Catalogue

Source studied: `github.com/sipeed/picoclaw` @ `49183d7e8daed0dba89ddbb6fcb60089401d9680`
(2026-07-23). Reference clone: `references/picoclaw` in this repo (git-ignored). Target: this
directory — a port built **middleware-by-middleware** on the `brute` gem, following the
`examples/hermes` pattern (FEATURES.md = the catalogue; every tool/middleware starts life as a
**skeleton**: real name, real description, real params, no-op body — filling in is then trivial).

Every entry lists: **what it does → exact mechanics → config/defaults → source refs → port status**.

Status legend: ✅ ported · 🟡 partial/subset · ⬜ not started · 🚫 deliberately out of scope
(interactive surface: channels, gateway, WebUI — see §2.18).

Totals: **25 built-in tools + 2 MCP-discovery tools + dynamic `mcp_<server>_<tool>` wrappers**,
**21 middleware-relevant subsystems**.

---

# Part 1 — Tools

Tool contract upstream (`pkg/tools/shared/base.go:10-15`): `Name()`, `Description()`,
`Parameters()` (JSON schema), `Execute(ctx, args) *ToolResult`. Optional `AsyncExecutor`
(`ExecuteAsync` + completion callback, base.go:183-189). `ToolResult` carries `ForLLM`, `ForUser`,
`Silent`, `IsError`, `Async`, `Media []string` (media:// refs), `ResponseHandled` (loop may end the
turn without a final assistant message; shared/result.go:18-62). Registry validates args against
the schema before Execute and recovers panics into error results (registry.go:251-362).

Per-agent allowlists come from AGENT.md frontmatter `tools:` (registry.go:43-61). All fs tools
share the sandbox: symlink-safe `os.Root` ops when `restrict_to_workspace` (default **true**), plus
`tools.allow_read_paths` / `tools.allow_write_paths` regex whitelists (media temp dir pattern
always appended to reads) — `pkg/tools/fs/filesystem.go:1098-1270`, `pkg/agent/instance.go:85-90,
449-469`.

## 1.1 Filesystem

### read_file — ⬜ (brute `FSRead` is a stand-in, different semantics)
- Two modes, one name. **bytes** (default): desc `Read the contents of a file. Supports pagination
  via \`offset\` and \`length\`.`; params `path` (string, req), `offset` (int, default 0), `length`
  (int, default = max size). **lines**: desc `Read a UTF-8 text file from the filesystem. Output
  always includes line numbers in the format \`LINE_NUMBER|LINE_CONTENT\` (1-indexed). Supports
  partial reads via \`start_line\` and \`max_lines\` for large text files.`; params `path` (req),
  `start_line` (int, default 1), `max_lines` (int).
- Gate: `tools.read_file.enabled` (true), `tools.read_file.mode` = bytes|lines,
  `tools.read_file.max_read_file_size` (65536).
- Mechanics: bytes mode sniffs binary (first 512B), probes with length+1, emits
  `[file: X | total: N bytes | read: bytes A-B]` + TRUNCATED/END-OF-FILE markers; lines mode
  rejects binary + offset-style args, same byte budget across prefixed lines.
  `pkg/tools/fs/filesystem.go:281-707`.

### write_file — ⬜ (brute `FSWrite` stand-in)
- Desc: `Write content to a file, replacing any existing content. Content is written byte-for-byte
  after argument decoding. Standard JSON escaping applies: \\n for newline and \\\\n for a literal
  backslash-n sequence. If the file already exists you must set overwrite=true, which replaces the
  ENTIRE file.` (+ dynamic suffix steering to edit_file/append_file when registered).
- Params: `path` (req), `content` (req), `overwrite` (bool, default false).
- Gate: `tools.write_file.enabled` (true).
- Mechanics: refuses overwrite without `overwrite=true` (error steers to edit/append); atomic write
  (temp + fsync + rename, 0600). `pkg/tools/fs/filesystem.go:869-981`.

### edit_file — ⬜ (brute `FSPatch` stand-in)
- Desc: `Edit a file by replacing old_text with new_text. The old_text must exist exactly in the
  file. Standard JSON escaping applies…` (same escaping note as write_file).
- Params: `path`, `old_text`, `new_text` (all string, all required).
- Gate: `tools.edit_file.enabled` (true).
- Mechanics: single-occurrence replace only — errors when absent or ambiguous (>1 match); returns a
  diff. `pkg/tools/fs/edit.go:19-80`, `pkg/tools/shared/diff_result.go`.

### append_file — ⬜
- Desc: `Append content to the end of a file. Standard JSON escaping applies…`
- Params: `path`, `content` (both string, required).
- Gate: `tools.append_file.enabled` (true).
- Mechanics: read-modify-write (creates if absent), silent result. `pkg/tools/fs/edit.go:83-162`.

### list_dir — ⬜ (brute `FSSearch`/`FSRead` stand-in)
- Desc: `List files and directories in a path`. Params: `path` (string, required — but a missing
  arg falls back to `.`).
- Gate: `tools.list_dir.enabled` (true).
- Mechanics: flat `DIR:  <name>` / `FILE: <name>` lines; read-restricted.
  `pkg/tools/fs/filesystem.go:994-1046`.

## 1.2 Shell

### exec — 🟡 (brute `Shell` + `SafetyGuard` carry the subset: sync run + deny patterns)
- Desc (verbatim): `Execute shell commands. Use background=true for long-running commands (returns
  sessionId). Use pty=true for interactive commands (can combine with background=true). Use
  poll/read/write/send-keys/kill with sessionId to manage background sessions. Sessions
  auto-cleanup 30 minutes after process exits; use kill to terminate early. Output buffer
  limit: 1MB.`
- Params: `action` (req, enum run|list|poll|read|write|kill|send-keys), `command`, `sessionId`,
  `keys` (named keys: up/down/enter/ctrl-c/f1-f12…), `data`, `background`, `pty` (strings coerced
  to bool), `cwd`, `timeout` (int seconds, 0 = none).
- Gate: `tools.exec.enabled` (true), `tools.exec.timeout_seconds` (60),
  `tools.exec.enable_deny_patterns` (true), `tools.exec.allow_remote` (true),
  `tools.exec.custom_deny_patterns` / `custom_allow_patterns` ([]).
- Mechanics: `sh -c` (powershell on Windows); deny-regex list (rm -rf, dd, fork bombs, `$(…)`,
  backticks, `|sh`, sudo, chmod NNN, curl|sh, docker run, git push, eval… — deny wins over allow);
  workspace path validation on every absolute-path token; `allow_remote=false` blocks non-internal
  channels; sync output capped at 10000 chars; background = PTY/pipe sessions with 8-char IDs, 1MB
  ring buffer, 30-min post-exit GC, send-keys → CSI/SS3 escapes. `pkg/tools/shell.go:52-1284`,
  sessions in `pkg/tools/session.go` (not itself a tool).
- Port gap: background sessions, PTY, send-keys, action multiplexer.

## 1.3 Web

### web_search — 🟡 (port has DuckDuckGo-only, `max_results` param; upstream is multi-provider)
- Desc: `Search the web for current information. Supports query, count, and an optional temporal
  range filter. Returns titles, URLs, and snippets from search results.`
- Params: `query` (req), `count` (int, 1-10, default 10), `range` (enum d|w|m|y).
- Gate: `tools.web.enabled` (true — key is `web`, not `web_search`); `tools.web.provider`
  ("auto"), `.proxy`, `.prefer_native` (true); per-provider `tools.web.<p>.*`: brave, tavily, kagi,
  sogou (default-enabled), duckduckgo, gemini, perplexity, searxng, glm_search, baidu_search.
- Mechanics: per-query provider pick: explicit → auto order perplexity,brave,kagi,searxng,tavily,
  gemini → sogou/duckduckgo (Han vs Latin script heuristic) → baidu/glm fallbacks; count clamped to
  provider max ≤10; tool unregistered entirely when no provider ready; hidden from the prompt when
  `prefer_native` and the LLM provider does native search. `pkg/tools/integration/web.go:1554-1978`.

### web_fetch — 🟡 (brute `NetFetch` stand-in)
- Desc: `Fetch a URL and extract readable content (HTML to text). Use this to get weather info,
  news, articles, or any web content.`
- Params: `url` (req), `maxChars` (int, min 100; registration default 50000).
- Gate: `tools.web_fetch.enabled` (true); `tools.web.{proxy,format(plaintext|markdown),
  fetch_limit_bytes(10MB),private_host_whitelist}`.
- Mechanics: http/https only; SSRF guard pre-flight + at dial; ≤5 redirects; 60s; body capped via
  MaxBytesReader; Cloudflare challenge retried once with honest UA; JSON pretty-printed / HTML→text
  or markdown; result JSON `{url,status,extractor,truncated,length,text}`.
  `pkg/tools/integration/web.go:2048-2291`.

## 1.4 Hardware (Linux-first; all default **disabled**)

### i2c — ⬜
- Desc: `Interact with I2C bus devices… Actions: detect (list buses), scan (find devices on a bus),
  read (read bytes from device), write (send bytes to device). Linux only.`
- Params: `action` (req, detect|scan|read|write), `bus` (`^\d+$`), `address` (0x03-0x77),
  `register`, `data` (int[]), `length` (1-256, default 1), `confirm` (bool, required true for
  writes).
- Gate: `tools.i2c.enabled` (false). SMBus ioctls; scan avoids AT24RF08-corrupting addresses.
  `pkg/tools/hardware/i2c.go:15-139`, `i2c_linux.go`.

### spi — ⬜
- Desc: `Interact with SPI bus devices… Actions: list… transfer (full-duplex)… read…. Linux only.`
- Params: `action` (req, list|transfer|read), `device` (`^\d+\.\d+$`), `speed` (default 1 MHz),
  `mode` (0-3), `bits` (default 8), `data` (int[]), `length` (1-4096), `confirm` (bool for
  transfer).
- Gate: `tools.spi.enabled` (false). `pkg/tools/hardware/spi.go:15-160`, `spi_linux.go`.

### serial — ⬜
- Desc: `Interact with host serial ports. Actions: list… read… write (send bytes with explicit
  confirmation). Supports Linux, macOS, and Windows.`
- Params: `action` (req, list|read|write), `port` (whitelisted names: ttyS/ttyUSB/ttyACM/ttyAMA/
  rfcomm/tty.*/cu.*/COMn), `baud` (115200), `data_bits` (8), `parity` (none|even|odd), `stop_bits`
  (1), `timeout_ms` (1000), `length` (1-4096), `data` (int[]) or `text`, `confirm` (bool for
  write).
- Gate: `tools.serial.enabled` (false). `pkg/tools/hardware/serial.go:51-395`.

## 1.5 Messaging & media

### message — ⬜ (needs channels; skeleton first, wire to a bus later)
- Desc (media disabled): `Send a text message to the user on a chat channel.` (media enabled:
  `…Supports text-only, media-only, or text with media attachments.`)
- Params: `content`, `channel`, `chat_id`, `reply_to_message_id` (all optional — default to the
  inbound turn's context); `media[]` objects `{path (req), type, filename}` only when media
  enabled. Required: `[content]`, or anyOf content/media when media enabled.
- Gate: `tools.message.enabled` (true), `tools.message.media_enabled` (false).
- Mechanics: routes via channel manager else message bus (5s timeout); media size-capped
  (`agents.defaults.max_media_size`, 20MB) into MediaStore; tracks per-round sends
  (`HasSentInRound`/`HasSentTo`) so the loop **suppresses a duplicate final response**; silent
  result. `pkg/tools/integration/message.go:57-338`, wiring `pkg/agent/agent_init.go:164-220`.

### reaction — ⬜
- Desc: `Add a reaction to a message. Defaults to the current inbound message when message_id is
  omitted.` Params: `message_id`, `channel`, `chat_id` (all optional).
- Gate: **none** (`IsToolEnabled` default → true).
- Mechanics: requires the channel to implement `ReactionCapable`, else error; silent result.
  `pkg/tools/integration/reaction.go:18-63`.

### send_file — ⬜
- Desc: `Send a local file (image, document, etc.) to the user on the current chat channel.`
- Params: `path` (req; relative resolved from workspace), `filename`.
- Gate: `tools.send_file.enabled` (true).
- Mechanics: MIME by magic bytes then extension; stores to MediaStore and returns
  `MediaResult + ResponseHandled` — delivered immediately, turn may end.
  `pkg/tools/fs/send_file.go:31-164`.

### send_tts — ⬜
- Desc: `Synthesize speech from text and send it as an audio file to the user.` Params: `text`
  (req; description instructs concise oral style, no markdown), `filename`.
- Gate: `tools.send_tts.enabled` (false) **and** a resolvable TTS provider (`voice.tts_model_name`
  or any model named *tts* with a key), else unregistered.
- Mechanics: synth to temp .ogg/.mp3 → MediaStore → `ResponseHandled` media result.
  `pkg/tools/integration/tts_send.go`, `pkg/audio/tts/tts.go:65-133`.

### load_image — ⬜
- Desc: `Load a local image file so you can analyze its contents with vision. Supported formats:
  JPEG, PNG, GIF, WebP, BMP. After calling this tool, describe or analyze the image in your next
  response.` Params: `path` (req).
- Gate: `tools.load_image.enabled` (true).
- Mechanics: ≤ max_media_size, MIME must be image/*; returns Media ref — the loop base64-inlines it
  into an `image_url` part on the next LLM call. Needs channel/chat context.
  `pkg/tools/fs/load_image.go:35-162`.

## 1.6 Skills registry

### find_skills — ⬜
- Desc: `Search for installable skills from skill registries. Returns skill slugs, descriptions,
  versions, and relevance scores. Use this to discover skills before installing them with
  install_skill.`
- Params: `query` (req), `limit` (int 1-20, default 5).
- Gate: `tools.skills.enabled` (true) AND `tools.find_skills.enabled` (true); registries
  `tools.skills.registries` (default clawhub `https://clawhub.ai` + github), search cache
  `{max_size:50, ttl_seconds:300}` (trigram-Jaccard ≥0.7 fuzzy LRU).
- Mechanics: fans out to all registries; markdown result ending "Use install_skill with the
  slug…"; silent. `pkg/tools/integration/skills_search.go:27-67`, `pkg/skills/search_cache.go`.

### install_skill — ⬜
- Desc: `Install a skill from a registry by slug. Defaults to GitHub when registry is omitted.
  Downloads and extracts the skill into the workspace. Use find_skills first to discover available
  skills.`
- Params: `slug` (req), `version`, `registry` (default github), `force` (bool).
- Gate: `tools.skills.enabled` AND `tools.install_skill.enabled` (both true).
- Mechanics: workspace mutex; installs to `{workspace}/skills/{slug}/`; force backs up/restores;
  ClawHub moderation (malware → delete+error, suspicious → warning); validates via loader, writes
  `.skill-origin.json`. `pkg/tools/integration/skills_install.go:43-294`.

## 1.7 Subagents (subturn limits: `agents.defaults.subturn` — max_depth 3, max_concurrent 5, default_timeout_minutes 5, concurrency_timeout_sec 30)

The subagent manager holds a clone of the parent registry taken **before** spawn/subagent/
spawn_status are added — subagents cannot recursively spawn (agent_init.go:364-368).

### spawn — ⬜
- Desc: `Spawn a subagent to handle a task in the background. Use this for complex or
  time-consuming tasks that can run independently. The subagent will complete the task and report
  back when done.`
- Params: `task` (req), `label`, `agent_id` (optional target agent).
- Gate: `tools.spawn.enabled` (true) AND `tools.subagent.enabled` (true).
- Mechanics: **AsyncExecutor** — immediate ack result, subturn runs in a goroutine as `critical`
  (survives parent end); result re-enters the parent via pendingResults; `agent_id` checked against
  the per-agent subagent allowlist; inherits model/maxTokens/temperature.
  `pkg/tools/spawn.go:20-157`.

### subagent — ⬜
- Desc: `Execute a subagent task synchronously and return the result. Use this for delegating
  specific tasks to an independent agent instance. Returns execution summary to user and full
  details to LLM.`
- Params: `task` (req), `label`.
- Gate: registered under the `spawn` gate (not its own key) with `tools.subagent.enabled`.
- Mechanics: blocking subturn; ForUser truncated to 500 chars; legacy fallback runs a raw tool loop
  with maxIterations=10. `pkg/tools/subagent.go:347-454`.

### spawn_status — ⬜
- Desc: `Get the status of spawned subagents. Returns a list of all subagents and their current
  state (running, completed, failed, or canceled), or retrieves details for a specific subagent
  task when task_id is provided. Results are scoped to the current conversation's channel and chat
  ID; all tasks are listed only when no channel/chat context is injected (e.g. direct programmatic
  calls via Execute).`
- Params: `task_id` (optional, e.g. "subagent-1"); `required: []`.
- Gate: `tools.spawn_status.enabled` (false) AND `tools.subagent.enabled`.
- Mechanics: per-conversation scoping prevents cross-chat leakage; sorted listing, counts by
  status, results truncated to 300 runes. `pkg/tools/spawn_status.go:19-178`.

### delegate — ⬜
- Desc: `Delegate a task to another agent and wait for the result. Use this when another agent is
  better suited to handle a specific task based on their capabilities. The target agent runs with
  its own workspace, model, and tools.`
- Params: `agent_id` (req), `task` (req).
- Gate: no tools.* key — registered only when **≥2 agents** configured; subject to the subagents
  allowlist.
- Mechanics: synchronous subturn in the target agent's workspace/model/tools; refuses
  self-delegation; result prefixed `[Response from agent "<id>"]`. `pkg/tools/delegate.go:21-101`.

## 1.8 Cron

### cron — 🟡 (port has add/list/remove with fugit expressions; missing: `at_seconds` one-shots, command jobs, get/update/enable/disable, per-channel ACL)
- Desc (verbatim, note the imperative): `Schedule, inspect, and update reminders, tasks, or system
  commands. IMPORTANT: When user asks to be reminded or scheduled, you MUST call this tool. Use
  'at_seconds' for one-time reminders (e.g., 'remind me in 10 minutes' → at_seconds=600). Use
  'every_seconds' ONLY for recurring tasks (e.g., 'every 2 hours' → every_seconds=7200). Use
  'cron_expr' for complex recurring schedules. Use 'command' to execute shell commands directly.`
- Params: `action` (req, add|list|get|update|remove|enable|disable), `name`, `message`, `command`,
  `command_confirm` (bool), `at_seconds` (int), `every_seconds` (int), `cron_expr`, `job_id`.
- Gate: `tools.cron.enabled` (true), `tools.cron.exec_timeout_minutes` (5, 0=none),
  `tools.cron.allow_command` (true), `tools.cron.command_allowed_remotes` ([]; "channel" |
  "channel:chatID" | "*"). Command jobs also need `tools.exec.enabled`.
- Mechanics: jobs at `{workspace}/cron/jobs.json`; schedule priority at > every > expr (zero =
  absent); `add` needs channel/chat context; command scheduling restricted to internal channels
  (cli/system/subagent) or allowlisted remotes, and needs `command_confirm=true` when
  `allow_command=false`; remote channels see/mutate only their own channel+chat jobs
  (GHSA-pv8c-p6jf-3fpp). Firing: command jobs run through an embedded exec tool and publish output;
  agent jobs run a full turn in a fresh session `agent:cron-<jobid>-<uuid>` and publish the
  response **only if the message tool didn't already deliver**.
  `pkg/tools/cron.go:40-662`, registration `pkg/gateway/gateway.go:836-867`.

## 1.9 Seahorse context tools (only when `agents.defaults.context_manager == "seahorse"`)

SQLite-backed alternative context manager (`{workspace}/sessions/seahorse.db`; unavailable on
mipsle/netbsd/freebsd-arm). Registers these two tools to all agents when active
(`pkg/agent/context_seahorse.go:54-57`). 🚫 for the initial port (legacy manager is the default),
catalogued for completeness.

### short_grep — ⬜
- Full-text search over summaries+messages: word/AND/OR/NOT/`%wildcard%` patterns; depth field
  (0 = from messages, 1+ = compressed); scope/role/time filters; bm25 rank under FTS5.
- Params: `pattern` (req), `scope` (both|summary|message), `role` (user|assistant), `last` ("6h",
  "7d", "2w", "1m"), `all_conversations` (bool), `since`/`before` (RFC3339), `limit` (default 20).
- Verbatim ~45-line description (syntax + return shape + examples) at
  `pkg/seahorse/tool_grep.go:25-69`.

### short_expand — ⬜
- Fetch full message content by IDs from short_grep results; tool_result parts deliberately omit
  content; media returned as on-disk paths.
- Params: `message_ids` (string[], req). Desc at `pkg/seahorse/tool_expand.go:24-46`.

## 1.10 MCP (dynamic)

### mcp_\<server\>_\<tool\> — ⬜
- Wrapper per server tool; names sanitized (lowercase, non-`[a-z0-9_-]`→`_`, ≤64 chars, FNV-1a
  hash suffix on collision/truncation); desc `[MCP:<server>] <tool description>`; params = the
  server's inputSchema passthrough.
- Gate: `tools.mcp.enabled` (false) + `tools.mcp.servers` entries (stdio command/args/env, or
  url+type sse|http|streamable-http; per-server `enabled`, `deferred`); per-agent `mcpServers:`
  allowlist.
- Mechanics: registered **hidden** (deferred) when discovery is on — invisible/uncallable until a
  discovery tool promotes them (TTL in turns, `TickTTL` per iteration); text >
  `tools.mcp.max_inline_text_chars` (16384) spilled to `{workspace}/.artifacts/mcp/*.txt` and
  replaced with an artifact tag; blobs → MediaStore; non-user-audience content dropped; emits
  mcp.* runtime events. `pkg/tools/integration/mcp_tool.go:92-670`, `pkg/agent/agent_mcp.go`.

### tool_search_tool_regex — ⬜
- Desc: `Search available hidden tools on-demand using a regex pattern. Returns JSON schemas of
  discovered tools.` Params: `pattern` (req, ≤200 chars, case-insensitive).
- Gate: `tools.mcp.discovery.enabled` (false) + `use_regex` (false) + ≥1 deferred server.
- Mechanics: matches hidden names+descs, caps at `max_search_results` (5), **promotes** matches
  (callable for `ttl` = 5 turns) and announces the unlock. `pkg/tools/search_tool.go:17-233`.

### tool_search_tool_bm25 — ⬜
- Desc: `Search available hidden tools on-demand using natural language query describing the action
  you need to perform. Returns JSON schemas of discovered tools.` Params: `query` (req).
- Gate: same but `use_bm25` (true when discovery on).
- Mechanics: BM25 over `name + description`, engine cached until registry version changes; same
  promote+announce. `pkg/tools/search_tool.go:100-297`.

## 1.11 Registration matrix (when is each tool present?)

- **Always on by default**: read_file, write_file, edit_file, append_file, list_dir, exec,
  web_search (if any provider ready), web_fetch, message, reaction, send_file, load_image,
  find_skills, install_skill, spawn, subagent, cron.
- **Default off**: i2c, spi, serial, send_tts (+needs provider), spawn_status, mcp (+discovery).
- **Conditional**: delegate (≥2 agents), short_grep/short_expand (seahorse), web_search (no ready
  provider → absent; native-search provider → hidden), send_tts (no TTS provider → absent).
- **Unknown tool names in `IsToolEnabled` → true** (config.go:1862-1915).
- Full `tools.*` config table with env vars: Part 3 below; upstream `pkg/config/config.go:1109-1144`,
  defaults `pkg/config/defaults.go:317-495`.

---

# Part 2 — Middleware

brute positions (see `examples/hermes/MIDDLEWARE.md` §0): **per-turn** (outside the tool loop),
**per-iteration** (around each LLM call), **per-tool-call** (`Brute::Turn::ToolPipeline` around
each execution). Two picoclaw additions: **daemon** (runs outside turns — in this port the systemd
timer / driver script owns it) and **prompt** (system-prompt assembly contributors).

## 2.1 Turn pipeline (the coordinator the stack wraps) — 🟡 brute core owns the loop
Upstream: `AgentLoop.runTurn` (`pkg/agent/turn_coord.go:17-286`) + four phases
(`pipeline_setup.go`, `pipeline_llm.go`, `pipeline_execute.go`, `pipeline_finalize.go`). Order:
session restore-point → assemble history+summary → build messages → resolve media → **proactive
compression if over budget** → persist root user msg → model routing → iteration loop (steering
poll → LLM call w/ retry+compaction → tool batch w/ hooks → subturn-result drain) → finalize
(save session, post-turn summarize, usage) → abort path rolls the session back to the restore
point. Everything below hangs off these points. Port mapping: brute's `Loop::ToolResult` +
`ToolPipeline` already provide the skeleton; the picoclaw-specific pieces are the middleware below.

## 2.2 Sessions — 🟡 (`Brute::Middleware::SessionLog` carries append-only JSONL; missing: keys/scoping/sanitize/restore)
- Keys: modern `sk_v1_<sha256(scope signature)>`; legacy `agent:<id>:…`; scope dimensions
  `session.dimensions` (default `["chat"]`, `session.dm_scope` sugar); aliases persist and migrate
  forward. Cron sessions `agent:cron-<job>-<uuid>`; heartbeat literal `heartbeat`; subturns
  ephemeral (never persisted, 50-msg cap).
- Store: `<workspace>/sessions/<key>.jsonl` + `<key>.meta.json` (`{key, summary, skip, count,
  created_at, updated_at, scope, aliases}`); truncation = **logical skip offset** (append-only,
  crash-safe), `Compact` reclaims; legacy `.json` snapshots auto-migrate (`pkg/memory/jsonl.go`,
  `migration.go`; fallback `pkg/session/manager.go`).
- On load: **sanitize history** — drop system messages, orphaned tool messages, tool results
  without matching assistant tool-calls, incomplete/duplicate call blocks (context.go:1023-1201).
- Per turn: persist root user/assistant/tool/steering/subturn/final messages incrementally; hard
  abort restores the pre-turn snapshot.
- Refs: `pkg/session/{key,allocator,scope}.go`, `pkg/agent/instance.go:479-504`.

## 2.3 System prompt assembly — 🟡 (`prompt.erb` + `Brute::PromptTemplate` cover identity/workspace/memory/skills; missing: layer/slot model, runtime part, summary part, turn profiles)
- Parts model: Layer (kernel 100 > instruction 80 > capability 60 > context 40 > turn 20) × Slot
  (identity, workspace, tooling, skill_catalog, active_skill, memory, output, runtime, summary…),
  joined `\n\n---\n\n`; static block cache-marked ephemeral (Anthropic cache_control /
  `prompt_cache_key=agent.ID`). `pkg/agent/prompt.go`.
- Static block (cached, mtime-invalidated on AGENT.md/SOUL.md/USER.md/MEMORY.md/skills):
  1. `# picoclaw 🦞 (version)` + workspace paths + numbered rules (tool use, helpfulness,
     "context summaries are approximate", "update memory/MEMORY.md when memorable")
     (context.go:147-198);
  2. workspace files — **AGENT.md** (with YAML frontmatter: name/description/tools/model/
     maxTurns/skills/mcpServers) else legacy AGENTS.md; SOUL.md; USER.md; IDENTITY.md (legacy only)
     (context.go:745-776, definition.go);
  3. `<skills>` XML catalog (§2.6);
  4. tool-discovery note when MCP discovery on;
  5. `# Memory` (§2.5);
  6. split-on-marker output policy when configured.
- Per-request parts: active skill bodies, agent-discovery peer list (when spawn allowed),
  "MCP server X is connected" notes, subturn profile override, `context.runtime` (time, OS/arch,
  channel/chat, sender), `context.summary`.
- Composition: exactly **one** system message; then sanitized history; then the user message.
  `pkg/agent/context.go:237-1201`, `prompt_contributors.go`, `prompt_turn.go`.

## 2.4 Heartbeat — ✅ (`HeartbeatGate` + flake systemd timer own it end-to-end)
- Daemon ticker (`heartbeat.enabled` true, `heartbeat.interval` 30 min, min 5) firing
  `ProcessHeartbeat` with session key `heartbeat`, `NoHistory`, no summary, no response.
- Skip-if-empty: `HEARTBEAT.md` content after the `Add your heartbeat tasks below this line:`
  marker must have a non-blank non-comment line, else **no LLM call** (missing file → template
  written, tick skipped). Prompt = fixed header ("# Heartbeat Check", current time, "If there is
  nothing that requires attention, respond ONLY with: HEARTBEAT_OK") + file content.
- Response always silent (user contact only via tools inside the turn); target channel from state
  manager's last channel, fallback `cli:direct`. `pkg/heartbeat/service.go:128-312`,
  `pkg/gateway/gateway.go:869-884`.
- Port gap: delivery to "last channel" (no channels yet — no-op by design).

## 2.5 Memory — 🟡 (MEMORY.md injected via prompt.erb; missing: daily notes)
- `memory/MEMORY.md` long-term + `memory/YYYYMM/YYYYMMDD.md` daily notes; prompt gets MEMORY.md +
  **last 3 days** of notes joined with `---` as `# Memory`, cached with the static block.
- No memory tools exist — the agent writes via write_file/edit_file (identity rule #4).
- `pkg/agent/memory.go`, injection `context.go:309-321`.

## 2.6 Skills — 🟡 (`.brute/skills` + `Brute::Tools::SkillLoad` + prompt listing; missing: XML catalog format, active/forced skills, registry find/install — see tools §1.6)
- Roots in priority: `<workspace>/skills` > `~/.picoclaw/skills` > cwd/builtin; first name wins.
  SKILL.md frontmatter (name `^[a-zA-Z0-9-]+$` ≤64, description ≤1024) else H1+first-paragraph.
- Prompt: catalog as `<skills><skill><name/><description/><location/><source/></skill></skills>`
  XML + rule "To use a skill, read its SKILL.md file using the read_file tool" — bodies **not**
  inlined. `# Active Skills` (full bodies, frontmatter stripped) only for AGENT.md `skills:` filter
  or `/use`-forced skills. `pkg/skills/loader.go`, `pkg/agent/context.go:278-306,1229-1289`,
  `agent_utils.go:481-520`.

## 2.7 Cron service — 🟡 (`CronSchedule` middleware + `CronStore` + `cron` tool; missing: at-oneshots, command jobs, fresh-session-per-firing, delivery dedup)
- Daemon loop (timer to earliest next run, woken on mutation); due jobs nil their next-run before
  execution (no double-fire). Kinds: `at` (DeleteAfterRun default), `every`, `cron` expr (gronx;
  `tz` field stored but unused).
- Delivery: command job → embedded exec tool, output published; agent job → full turn in a
  **brand-new session** `agent:cron-<jobID>-<uuid>`, response published only if the message tool
  didn't already send to that chat this round (`PublishResponseIfNeeded`).
- Persistence `cron/jobs.json` `{version:1, jobs:[…]}` atomic 0600.
- `pkg/cron/service.go`, `pkg/tools/cron.go:594-662`, `pkg/agent/agent_outbound.go:42-92`.

## 2.8 Steering — 🟡 (`SteeringLoop` drains `steer.jsonl` between tool batches; missing: modes, interrupts, post-turn drain, graceful terminal call)
- Per-session in-memory queue (max 10/scope); `agents.defaults.steering_mode` = `one-at-a-time`
  (default) | `all`. Enqueue path: a message arriving for a busy session becomes steering instead
  of a new turn.
- Injection points: iteration 1 (initial poll), after a no-tool-call response, after every tool
  execution. On injection: remaining tool calls in the batch get placeholder results ("Skipped due
  to queued user message."), messages appended to context + session, `agent.steering.injected`
  emitted.
- Post-turn: `Continue()` drains the queue as fresh turns (placeholder turn claims the session
  against races).
- Interrupts: `InterruptGraceful(hint)` → next LLM call is terminal (hint appended, **no tools**);
  `HardAbort` → cancel + cascade to subturns + **session rollback**.
- `pkg/agent/steering.go`, `agent_steering.go`, `agent_stop.go`.

## 2.9 Compaction / context budget — 🟡 (`Compaction` summarizes dropped turns at `max_history`; missing: token-based triggers, proactive budget, emergency 50% drop)
- Triggers (legacy manager): post-turn `maybeSummarize` when `len(history) >
  summarize_message_threshold` (20) OR est. history tokens > `context_window ×
  summarize_token_percent / 100` (75); **proactive** pre-LLM check `Σtokens(messages+system+tools)
  + max_tokens > context_window`; **reactive** on context-window API errors (notice → compress →
  rebuild protecting the active-turn tail → retry, max_llm_retries 2 w/ linear backoff 2s).
- `forceCompression`: parse history into turns (user-message boundaries, never split tool-call
  sequences), drop oldest ~50%, append `[Emergency compression dropped N oldest messages…]` to the
  stored summary. `trimHistoryToFitContextWindow` drops oldest whole turns.
- Summarizer: LLM (primary provider, max_tokens=agent's, temp 0.3, prompt_cache_key, 3 retries);
  cut at a safe boundary keeping last 4 messages; only user/assistant summarized; >10 messages →
  split in halves + merge pass; total failure → deterministic truncation fallback; on success
  SetSummary + TruncateHistory + `agent.session.summarize`.
- Token estimator: max(content chars, parts chars + 20/part) + reasoning + tool-call fields + 12,
  all × 2/5, **+256 per media item**; tool defs = (name+desc+params JSON + 20) × 2/5.
- `context_window` default 0 → 4×max_tokens (max_tokens default 8192; DefaultConfig 32768).
- Refs: `pkg/agent/context_legacy.go`, `context_budget.go`, `pipeline_llm.go:291-450`,
  `pkg/tokenizer/estimator.go`.

## 2.10 Seahorse (alternative context manager) — 🚫 initial port / ⬜ later
SQLite session store with hierarchical summaries (leaf fanout 8/condensed 4, leaf chunk 20k tokens,
compact at 75% window, fresh tail 32 msgs), budget = window − max_tokens, bootstraps existing
JSONL at startup, registers short_grep/short_expand (§1.9). `pkg/agent/context_seahorse.go`,
`pkg/seahorse/`. Pluggable via `agents.defaults.context_manager` ("legacy" default) — the port
should expose the same seam.

## 2.11 LLM-call policy (per-iteration) — ⬜ (brute OpenRouter completion is a single call; none of this exists)
- **Fallback chain**: candidates = primary + `model_fallbacks` (per-candidate provider instances
  from model_list, own keys/base); skip in-cooldown → RPM gate (`TryAcquire`, last candidate waits)
  → run → classify error: non-retriable (auth/format) aborts; retriable (timeout/network/
  rate_limit/overloaded/billing) → cooldown `min(1h, 1m·5^min(n-1,3))`, billing
  `min(24h, 5h·2^…)`; all failed → FallbackExhaustedError. Single candidate → plain Chat.
  `pkg/providers/fallback.go`, `cooldown.go`, `ratelimiter.go` (`model_list[].rpm` token bucket).
- **Light/heavy routing**: rule classifier scores the turn (attachments → 1.0; >200 tokens +0.35;
  fenced code +0.40; recent tool calls +0.25; depth >10 +0.10); score < `routing.threshold` (0.35)
  → light model. `pkg/routing/`, selectCandidates `turn_coord.go:306-334`.
- **Media routing**: current-turn media → image_model chain (bypasses light); vision-unsupported
  errors → hard error advising `agents.defaults.image_model`. `pkg/agent/llm_media.go`.
- **Thinking levels**: `off|low|medium|high|xhigh|adaptive` from model_list, applied only to
  ThinkingCapable providers; `off` strips reasoning. `pkg/agent/thinking.go`.
- **Native search swap**: `tools.web.prefer_native` + provider NativeSearchCapable → drop the
  web_search tool def, set native_search option. `prompt_turn.go:56-72`.
- Retries: `max_llm_retries` (2), `llm_retry_backoff_secs` (2, linear).

## 2.12 Tool-call policy (per-tool-call) — 🟡 (`WorkspaceGuard` + `SafetyGuard` cover paths/exec; missing: schema validation, allowlist, sensitive filter, async, dedup, ResponseHandled)
Upstream `ExecuteTools` (`pipeline_execute.go:111-864`) wraps every call in:
1. turn-profile tool allowlist gate (deny → synthetic tool error, `agent.tool.exec_skipped`);
2. `BeforeTool` hook (continue/modify/**respond**/deny_tool/abort) → `ApproveTool` hook
   (fail-closed, timeout 60s) → `AfterTool` hook;
3. registry arg validation against the declared schema; panic recovery into error results;
4. **sensitive-data filter** on ForLLM (`tools.filter_sensitive_data` true, min length 8);
5. media delivery when `result.Media` + `ResponseHandled` (turn may end with "Requested output
   delivered via tool attachment.");
6. **async tools**: completion re-enters as an inbound **"system"-channel** message addressed to
   `channel:chatID`, sender `async:<tool>`;
7. **final-response dedup**: if the message tool already sent to the chat this round, the final
   assistant response is not re-published;
8. optional tool-feedback user message (`agents.defaults.tool_feedback`, off by default);
9. steering poll after each tool; hidden-tool `TickTTL` at batch end.
Port notes: brute `Turn::ToolPipeline` is the seam; WorkspaceGuard/SafetyGuard already implement
the path/deny-pattern subset (§2.15).

## 2.13 Hooks — ⬜
- Points: `BeforeLLM`/`AfterLLM`, `BeforeTool`/`AfterTool`, `ApproveTool`,
  `RuntimeEventObserver`. Actions: continue/modify/respond/deny_tool/abort_turn/hard_abort
  (respond = hook fabricates the ToolResult, bypassing approval — security note).
- Ordering: Source (in-proc before process) → Priority → Name. Timeouts: observer 500ms /
  interceptor 5s (fail-open) / approval 60s (**fail-closed**). Payloads cloned; BeforeLLM edits to
  system prompt or tool defs are **reverted with a warning** (prompt-cache invariant).
- Process hooks: subprocess via isolation, JSON-RPC 2.0 over stdio (`hook.hello`,
  `hook.before_llm`, …). Config `hooks.enabled` (true), `hooks.defaults.{observer,interceptor,
  approval}_timeout_ms`, `hooks.builtins.<name>.{enabled,priority,config}`,
  `hooks.processes.<name>.{command,dir,env,observe,intercept}`.
- **No built-in hooks ship at this commit** — the mechanism is the feature.
- `pkg/agent/hooks.go:195-930`, `hook_mount.go`, `hook_process.go`.

## 2.14 Evolution — 🟡 (`EvolutionLog` = hot path; missing: cold path, modes)
- Hot: on `agent.turn.end` → LearningRecord `{kind:"task", summary=user msg ≤160 chars,
  output ≤1200, success, skills}` appended to `task-records.jsonl`; per-skill usage profiles.
  Heartbeat turns excluded.
- Cold: cluster tasks → patterns (`min_task_count` 2, `min_success_ratio` 0.7) → recall similar
  skills → LLM draft generation/review → in `apply` mode write skill updates into the workspace
  (with backups); lifecycle (active/cold/archived). Trigger: after_turn (default in draft/apply) |
  scheduled at `cold_path_times` | manual.
- Config: `evolution.enabled` (false), `evolution.mode` = observe|draft|apply (observe default),
  `state_dir` (`<workspace>/state/evolution`).
- `pkg/evolution/runtime.go`, `pkg/agent/evolution_bridge.go`.

## 2.15 Guards & isolation — 🟡 (`WorkspaceGuard` symlink-resolved path check + `SafetyGuard` deny patterns ported; missing: bwrap isolation, approval)
- Workspace sandbox: symlink-safe root ops, `restrict_to_workspace` (true),
  `allow_read_outside_workspace` (false), allow_read/write_paths regexes (§Part 1 preamble).
- Exec deny/allow patterns: deny always wins (§1.2 exec).
- **Isolation**: `isolation.enabled` (false) → every subprocess (exec tool, process hooks) launched
  via bubblewrap on Linux (**required**, fails closed), mount plan = expose_paths + executable +
  cwd(rw) + absolute-path args, env redirected to runtime-user-env. `pkg/isolation/`,
  `isolation.expose_paths[] = {source, target, mode: ro|rw}`.
- Approval: picoclaw's seam is the `ApproveTool` hook (§2.13); the port could equally use a
  per-tool-call middleware (hermes `write_approval.rb` is the local precedent).

## 2.16 Runtime events — ⬜
- In-process bus: `Event{Kind, Source, Scope, Correlation, Severity, Payload, Attrs}`;
  subscriptions with filters, backpressure (Block/DropNewest), concurrency; kinds `agent.*`
  (turn.start/end, llm.request/response/retry, tool.exec_*, steering.injected,
  context.compress, session.summarize, subturn.*, interrupt.received, error), `channel.*`, `bus.*`,
  `gateway.*`, `mcp.*`.
- Subscribers: runtime event logger (`events.logging.{enabled:true, include:["agent.*"],
  min_severity:"info", include_payload:false}`), hook observers, evolution bridge (turn.end),
  channels manager.
- `pkg/events/`, `pkg/agent/runtime_event_logger.go`, kinds `pkg/events/kind.go`.

## 2.17 State manager — ⬜ (trivial)
- `<workspace>/state/state.json` `{last_channel, last_chat_id, timestamp}` (atomic 0600; migrates
  legacy `state.json`). Written on every non-internal-channel turn; read by heartbeat (+devices)
  for delivery targeting. `pkg/state/state.go`, writer `agent_inject.go:63-75`.

## 2.18 Media store — ⬜
- `MediaStore`: Store(localPath, meta, scope) → `media://<uuid>`; refcounted, per-entry cleanup
  (`delete_on_cleanup` | `forget_only`); files in a tmp dir (auto-added to read-allow patterns);
  janitor `tools.media_cleanup.{enabled:true, max_age_minutes:30, interval_minutes:5}`.
- Resolution into LLM messages (SetupTurn + each iteration): refs → path tags `[image:/path]` etc.
  replacing generic placeholders; **current-turn** tool images also base64-inlined via a synthetic
  user message placed *after* the contiguous tool block (preserves assistant→tool adjacency);
  historical refs path-only, unresolvable silently dropped.
- `pkg/media/store.go`, `pkg/agent/agent_media.go:60-149`.

## 2.19 Commands (pre-turn slash layer) — 🚫 mostly (autonomous port has no chat surface) — catalogue the stateful few
`/stop` (interrupt + steering clear), `/clear` (ContextManager.Clear), `/use <skill>` (arms
pending skill → ForcedSkills next turn), `/switch model|channel` (hot-swap provider+candidates),
`/btw <q>` (side question: history context, no session writes, no tools, own cache key),
`/context` (usage stats), `/subagents`, `/show`, `/list`, `/check`, `/reload`, `/start`, `/help`;
unknown `/…` falls through to the LLM. Port value: `/stop`-as-interrupt and `/use`-as-forced-skill
semantics can map to files in the workspace (like steer.jsonl). `pkg/commands/builtin.go`,
`pkg/agent/agent_command.go`, `turn_coord.go:359-623`.

## 2.20 Turn profiles — ⬜
- `agents.defaults.turn_profile.{history,system_prompt,skills,tools}` (modes default|off|custom):
  history off ⇒ NoHistory + no summary; tool/skill gating filters defs and prompt parts per turn;
  used for heartbeat/subturns/side questions. `pkg/config/turn_profile.go`,
  `pkg/agent/turn_profile_policy.go`, `prompt_turn.go:11-54`.

## 2.21 Bus & channels — 🚫 (interactive surface) with three **must-keeps**
Skip: concrete channels (telegram/discord/…), typing/placeholder cosmetics, per-channel rate
limits, streaming publisher, ASR/TTS, webhooks, WebUI. Keep for agent behavior:
1. **internal channel set** `{cli, system, subagent}` — heartbeat/cron/exec security checks key off
   it (`pkg/constants/channels.go`);
2. **"system"-channel convention** — async tool results re-enter as inbound turns (§2.12.6);
3. **message-tool delivery dedup** (§2.12.7) — without it every proactive turn double-posts.
`pkg/bus/bus.go`, `pkg/channels/manager.go`, `pkg/agent/agent_outbound.go:42-92`.

---

# Part 3 — Config appendix (what the port's `config.json` must grow)

`agents.defaults.*` (config.go:423-459): workspace, `restrict_to_workspace` (true),
`allow_read_outside_workspace` (false), provider/model_name/model_fallbacks, image_model(+fallbacks),
`max_tokens` (8192; DefaultConfig 32768), `context_window` (0 → 4×max_tokens), `temperature` (0.7),
`max_tool_iterations` (20; DefaultConfig 50), `summarize_message_threshold` (20),
`summarize_token_percent` (75), `max_media_size` (20MB), `routing.{enabled,light_model,
threshold:0.35}`, `steering_mode` ("one-at-a-time"), `max_parallel_turns` (1),
`subturn.{max_depth:3, max_concurrent:5, default_timeout_minutes:5, concurrency_timeout_sec:30,
default_token_budget:0}`, `tool_feedback.{enabled:false, max_args_length:300}`,
`split_on_marker` (false), `context_manager` ("legacy"), `max_llm_retries` (2),
`llm_retry_backoff_secs` (2), `turn_profile{…}`.

`tools.*`: full table in §1.11 sources — keys: allow_read_paths/allow_write_paths,
filter_sensitive_data(true)/filter_min_length(8), web.{enabled,provider:auto,prefer_native,proxy,
format,fetch_limit_bytes:10MB,private_host_whitelist, <10 providers>}, web_fetch.enabled,
cron.{enabled,exec_timeout_minutes:5,allow_command,command_allowed_remotes},
exec.{enabled,timeout_seconds:60,enable_deny_patterns:true,allow_remote:true,custom_deny/allow},
skills.{enabled,registries:clawhub+github,max_concurrent_searches:2,search_cache{50,300}},
media_cleanup.{true,30,5}, mcp.{enabled:false,discovery{enabled,ttl:5,max_search_results:5,
use_bm25:true,use_regex:false},max_inline_text_chars:16384,servers}, and per-tool
`*.enabled` for append_file, edit_file, find_skills, i2c(false), install_skill, list_dir,
load_image, message(+media_enabled:false), read_file{mode:bytes,max_read_file_size:65536},
send_file, send_tts(false), serial(false), spawn, spawn_status(false), spi(false), subagent,
write_file.

`heartbeat.{enabled:true, interval:30(min 5)}` · `evolution.{enabled:false, mode:observe,
state_dir, min_task_count:2, min_success_ratio:0.7, cold_path_trigger:after_turn, cold_path_times}` ·
`hooks.{enabled:true, defaults{500/5000/60000ms}, builtins, processes}` ·
`events.logging.{enabled:true, include:["agent.*"], min_severity:info}` ·
`isolation.{enabled:false, expose_paths}` · `session.{dimensions:["chat"], dm_scope}`.
Home: `PICOCLAW_HOME` else `~/.picoclaw`. Example: `config/config.example.json` (v3).

---

# Part 4 — Implementation checklist (skeletons to create)

Following the hermes pattern: one file per tool under `tools/` (`ClassName < Brute::Tool`,
verbatim `description`, full `params`, `execute` returning `JSON.dump("error" => "not
implemented", "tool" => name)`), one per middleware under `middleware/` (documented `call(env)`
no-op pass-through with the env contract in the header comment).

**Tools** (existing: `cron_tool` 🟡 upgrade to full action set, `web_search` 🟡 align params to
`count`/`range`, `safety_guard`/`workspace_guard`/`tool_wrapper` ✅ keep as the per-tool-call guard
layer):
`read_file` (both modes) · `write_file` · `edit_file` · `append_file` · `list_dir` · `exec`
(actions/background/PTY) · `web_fetch` · `i2c` · `spi` · `serial` · `message` · `reaction` ·
`send_file` · `send_tts` · `load_image` · `find_skills` · `install_skill` · `spawn` · `subagent` ·
`spawn_status` · `delegate` · `tool_search_tool_regex` · `tool_search_tool_bm25` · `mcp_tool`
(wrapper factory) · (`short_grep`/`short_expand` only if seahorse is ever ported).

**Middleware** (existing: `heartbeat_gate` ✅, `cron_schedule` 🟡, `evolution_log` 🟡 hot-path,
`compaction` 🟡, `steering_loop` 🟡):
`session_store` (keys/scoping/sanitize/restore on top of SessionLog) · `memory_files`
(MEMORY.md + 3-day daily notes) · `skills_catalog` (XML catalog + active/forced skills) ·
`context_budget` (token estimator + proactive trim) · `summarize` (threshold/percent triggers,
split-merge summarizer — extend `compaction`) · `emergency_compression` (50% turn drop on
context-error retry) · `steering` (modes, graceful-terminal interrupt, hard-abort rollback,
post-turn drain — extend `steering_loop`) · `subturns` (spawn machinery: depth/concurrency/token
budget, pendingResults injection) · `fallback_chain` (candidates, cooldowns, RPM buckets) ·
`model_router` (light/heavy classifier) · `media_store` + `media_resolver` (media:// lifecycle,
path tags, base64 inlining) · `hooks` (5 points, process-hook JSON-RPC transport) ·
`evolution_cold_path` (clustering, drafts, modes) · `runtime_events` (bus + logging subscriber) ·
`state_manager` (state.json last-channel) · `tool_policy` (schema validation, allowlist,
sensitive-data filter, async-result re-injection, message-tool dedup, ResponseHandled — the
per-tool-call pipeline layer that WorkspaceGuard/SafetyGuard already hang off) · `turn_profile`
(history/system/skills/tools gating).

**Deliberately not ported** (interactive surface): concrete channels, gateway/WebUI, streaming
publisher, ASR/TTS pipeline, typing/placeholder cosmetics, webhook mux. **Doesn't exist upstream
(don't invent)**: built-in hook implementations, memory/session-search tools (beyond seahorse
grep/expand), cron `tz` handling, non-silent heartbeat output.
