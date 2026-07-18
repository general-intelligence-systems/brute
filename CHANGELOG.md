# Changelog

All notable changes to Brute are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [3.1.0] - 2026-07-18

### Added

- `Brute::Middleware::Checkpoint` — durable execution for the tool loop.
  Sits just inside `Loop::ToolResult` and snapshots the conversation to an
  append-only JSONL chain after every pass (one checkpoint per LLM call +
  tool batch). Each record carries its parent checkpoint's id, so the chain
  supports:
  - **resume** (`resume: :latest`) — a crash mid-turn costs at most one
    iteration instead of the whole turn
  - **time travel** (`resume: "<checkpoint id>"`) — restart from any snapshot
  - **forking** — checkpoints written after a time-travel resume carry the
    resumed id as `parent_id`, branching the chain in place
- `examples/agents/08_checkpoints.rb` — runnable checkpoint demo: fresh turn,
  `BRUTE_CHECKPOINT=latest` to resume, `BRUTE_CHECKPOINT=<id>` to fork.
- `Checkpoint` entry in the middleware catalog docs.

## [3.0.1] - 2026-07-18

The 3.0.0 gem shipped without the LLM-library decoupling work that was
intended for that release. 3.0.1 lands it as a patch. **The public API
changes below are breaking relative to the 3.0.0 gem** — treat this
release as the real 3.0.0 for integration purposes.

### Changed
- **Brute no longer depends on `ruby_llm`.** `require "ruby_llm"` is
  gone from `lib/brute.rb`, and the `lib/ruby_llm/` directory (which
  previously held Brute's transport shim) has been removed. The user's
  inline `run` proc is now responsible for choosing an LLM library.
- **`Brute.rubyllm_tools` → `Brute.tools`.** The new helper returns a
  `{ name_sym => Brute::Tools::Adapter }` hash. Each adapter exposes
  `#to_h` — a neutral JSON-Schema-ish tool definition the `run` proc
  translates to whatever its LLM library expects.

### Added
- `Brute::MessageTransport` and adapters for `anthropic`, `openai`,
  `llm`, and `ruby_llm` under `lib/brute/message_transport/`. Pick the
  transport that matches your LLM library; the `run` proc converts
  `env[:messages]` (Brute::Message values) to the library's format,
  makes the call, and appends responses back as `Brute::Message`
  values.
- `Brute::Tool` (`lib/brute/tool.rb`) — base class for tools.
- Example scripts: `examples/anthropic.rb`, `examples/openai.rb`,
  `examples/llm.rb`, `examples/ruby_llm.rb`.
- Documentation site under `docs/` (Jekyll), including
  `_core_features/message-transports.md`.

### Fixed
- Middleware and tool internals updated for the transport-agnostic
  message flow: `messages.rb`, seven middleware (`002_session_log`,
  `004_summarize`, `006_loop`, `010_max_iterations`, `020_system_prompt`,
  `040_compaction_check`, `070_tool_pipeline`), turn pipeline
  (`agent_pipeline`, `pipeline`, `tool_pipeline`), all `fs_*` tools,
  `net_fetch`, `question`, `shell`, `skill_load`, `sub_agent`,
  `todo_read`, `todo_write`, and `brute_cli/providers/shell_response`.

### Migration from 3.0.0
- Replace `Brute.rubyllm_tools(tools)` with `Brute.tools(tools)` and
  translate the resulting adapters' `#to_h` output for your LLM
  library, or use one of the bundled `Brute::MessageTransport::*`
  adapters.
- Add your LLM library (`ruby_llm`, `llm`, `openai`, `anthropic`, …)
  to your own Gemfile — Brute no longer pulls one in.

## [3.0.0] - 2026-07-05

Initial 3.0.0 gem release (superseded by 3.0.1 — see above).
