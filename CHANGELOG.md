# Changelog

All notable changes to Brute are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [5.0.3] - 2026-08-24

### Fixed

- `Brute::Completion::OpenRouter` advertises `env[:tools]` to the provider.
  The `ToolPipeline` middleware puts the tools it executes on the env for
  exactly this reason; the OpenRouter completion was the one that ignored them,
  so every pipeline had to serialize its tool list a second time by hand and
  pass it as a `tools:` option. A `tools:` option given at point of use still
  wins, so a pipeline that serialized its own list keeps working.

- `Brute::Completion::OpenRouter` falls back to `env[:model]`, the way the
  other completions do, so a middleware can route a turn to another model.
  A `model:` option given at point of use still wins, and with neither the
  gem's own `openrouter/auto` default stands.

- `Brute::Completion::RubyLLM` no longer raises `NoMethodError` when there are
  tools to advertise: it called `to_ruby_llm` on the tool adapter, which does
  not exist. Adapters are now presented to ruby_llm's providers through
  `Brute::Completion::RubyLLM::Tool`, a wrapper answering `name`,
  `description`, `params_schema`, `provider_params` and `call`; a tool already
  written against `RubyLLM::Tool` is passed through untouched.

## [5.0.1] - 2026-08-24

### Removed

- `Brute::Middleware::Tracing`. Telemetry only ever observes, and a middleware
  earns its place in the stack by being able to alter or skip what is below it,
  so it belongs outside `Brute::Middleware` — use `Brute::Contrib::Otel`, or
  your own subscriber on the hooks the layer wrapped. Everything it measured is
  already an event: `:llm_duration` around every provider call, `:duration`
  around every middleware, `:turn_duration` around the whole turn, and token
  usage at `env[:metadata][:last_llm_usage]`. Its token half had measured
  nothing since 5.0 in any case — it read `usage` off what the app below
  returned, and every completion returns the turn env, so the tokens it logged
  were always `?` and `env[:metadata][:tokens]` was never written.

  This is a public name removed outside a major version, against the usual
  rule: 5.0.0 shipped the same day, so nothing has had the chance to depend on
  it. To keep the log lines, subscribe:

  ```ruby
  agent.on(Brute::Hooks::LLM_DURATION_EVENT) do |env, started, finished|
    usage = env.dig(:metadata, :last_llm_usage)
    logger.debug("[brute] LLM response: #{usage&.total || "?"} tokens, #{(finished - started).round(2)}s")
  end
  ```

## [5.0.0] - 2026-08-24

### Added

- `Brute::Completion::RubyLLM`, `Brute::Completion::LangChain` and
  `Brute::Completion::LLMrb`, restoring the ruby_llm, langchainrb and llm.rb
  backends that went with the old `Middleware::Completion` family, in the
  current shape: terminal `run` apps that emit through the pipeline's hooks
  and convert messages with the matching `MessageTransport`. Each requires
  its own provider gem at point of use, so installing Brute pulls in none of
  them.
- `Brute::UsageDetection` — a strategy per provider (`OpenRouter`, `RubyLLM`,
  `LLMrb`, `LangChain`), each answering the same `UsageDetection::Usage`
  (`input`, `output`, `total`, `reasoning`, `cache_read`, `cache_write`,
  `cost`, `raw`), or nil when the provider reported nothing. A strategy
  extracts and nothing else — no deriving, summing or accumulating. Every completion
  now records one at `env[:metadata][:last_llm_usage]`, where before only
  OpenRouter did, and it stored that provider's raw hash. **A reader of
  `last_llm_usage` must move from `usage["total_tokens"]` to `usage.total`.**
- `MessageTransport.usage_metrics(result)` — a transport knows its own
  library's response shape, so it is the one that answers which
  `UsageDetection::Usage` a call produced. The base answers nil, and the
  transports for the four providers above answer through their detector.
- `Brute::Middleware::Base`, the parent of every middleware. It takes the next
  app, swallows whatever else a subclass declares, and passes the turn
  through; it includes `Brute::Hooks`, so a subclass writes `ENTER_EVENT`
  rather than `Brute::Hooks::ENTER_EVENT`. Every bundled middleware now
  inherits from it, and so should yours.
- Faraday-backed completions now run on async-http. `Brute::Completion.async_faraday!`
  requires `async/http/faraday/default` when Faraday is in play, and OpenRouter,
  RubyLLM and LangChain call it after requiring their provider gem. Faraday's own
  default is Net::HTTP, which works under Async but opens a fresh connection per
  request; async-http keeps them persistent and speaks HTTP/2. Adds a runtime
  dependency on `async-http-faraday`.
- Timed events. `emit` now takes an optional block: the block is the work, and
  subscribers fire once it is done, called as
  `|env, started, finished, *extras|` rather than `|env, *extras|`. Both
  stamps are monotonic, and they are reported from an `ensure` so work that
  raises is still timed. `emit` returns the block's own value, so a caller
  wraps work in place:
  `emit(DURATION_EVENT, env, self) { @app.call(env) }`. Every pair of events
  now has one: `:turn_duration` between `:turn_start` and `:turn_end`,
  `:duration` between `:enter` and `:exit`, `:llm_duration` between
  `:before_llm` and `:after_llm`, and `:tool_duration` between
  `:before_tool` and `:after_tool` — the last wrapping only the tool's own
  execution, so a call answered by `before_tool` or denied by `approve_tool`
  never fires it.
- `:middleware_added`, `:enter`, `:duration` and `:exit`. `use` now emits
  `:middleware_added` with an empty env, the middleware and every argument it
  was given; each layer then emits `:enter` before its work, `:duration`
  wrapping that work (so subscribers are handed `started` and `finished`
  without correlating anything by hand — which recursion through
  `Loop::ToolResult` made unreliable), and `:exit` when it is done, each
  handing the subscriber the layer itself. A turn used to be opaque between
  the LLM calls. `:exit` fires from an ensure, so a layer that raises is still
  reported.
- `use` and `run` bind an `emit(event, env, *extras)` onto the object they are
  given, tied to that builder's own store, so a layer fires events at the
  pipeline it belongs to: `emit(ENTER_EVENT, env, self)`. A lambda cannot
  carry one, so `run ->(env) { ... }` warns that its events will not fire; an
  object that already answers to `emit` raises rather than being shadowed.
- A constant per event name — `Brute::Hooks::TURN_START_EVENT`,
  `ENTER_EVENT`, `BEFORE_TOOL_EVENT` and so on — replacing the unused
  `Hooks::EVENTS` array. Emit and subscribe through those rather than bare
  symbols.

### Changed

- **`emit` answers nothing.** It is an emitter: it announces, and a
  subscriber's return value is not a signal. `ToolPipeline` used to read the
  array of subscriber results as a control channel — the last truthy return
  from `:before_tool` became the tool's answer, and a `false` or String from
  `:approve_tool` denied the call — which made every observer of those events
  an accidental participant, since anything a block happens to evaluate to
  (`span.add_event`, a `Logger#info`, an `<<`) is truthy. A subscriber now
  takes part by mutating the call env it was handed: set `call[:result]` to
  answer without executing, set `call[:denied]` to `true` or a String to
  refuse. The block form answers nothing either: the block is the work, and a
  caller that needs the work's value takes it inside the block.

- **Breaking for tool and error subscribers.** `Brute::Hooks#emit` now takes
  the turn env first and any event-specific extras after it, and calls every
  subscriber the same way: `subscriber.call(env, *extras)`. `:before_tool`,
  `:approve_tool` and `:after_tool` now yield `(env, call_env)` instead of just
  the call env; `:faraday_error`, `:open_router_server_error` and
  `:standard_error` now yield `(env, error)` instead of the bare exception.
  Subscribers to `:turn_start`, `:turn_end`, `:before_llm`, `:after_llm` and
  `:llm_failure` are unaffected. Update tool subscribers from `{ |call| ... }`
  to `{ |_env, call| ... }` — the turn env is now available at every event, so
  a listener can log the system prompt, the outgoing messages and the tool
  arguments without threading state through the stack.

- OpenTelemetry is no longer middleware. The four `Middleware::Otel*` classes
  (all of them commented-out pass-throughs against a long-dead env shape) are
  replaced by `Brute::Contrib::Otel.subscribe(agent)`, which registers hooks:
  `turn_start`/`turn_end` open and finish the span, `after_llm` records usage,
  `before_tool`/`after_tool` add a span event each. Telemetry only observes,
  and observation needs no stack position. The tracer is injectable, and
  without the OpenTelemetry SDK loaded `subscribe` does nothing.

### Removed

- The three deprecations that came due in 5.0: `Brute::Changelog` (use
  `GemKit::Release::Changelog`), `Brute::Deprecate` (use `GemKit::Deprecate`)
  and `Brute::Middleware::OpenRouter::Completion` (use
  `Brute::Completion::OpenRouter`).

- **`env[:hooks]` is gone.** `AgentPipeline#start` no longer seeds it and
  nothing reads it: emitters get their store from the builder that made them.
  Anything that instantiated a middleware directly and passed `hooks:` in env
  has to go through a pipeline now — a bare `Middleware.new(app).call(env)`
  raises `NoMethodError` on `emit` instead of silently emitting nothing.

## [4.3.2] - 2026-08-23

### Fixed

- `Brute::Completion::OpenRouter.new` no longer takes a leading `app`
  positional argument. It never used it — the class is a completion
  middleware, the terminal step of a turn, not a passthrough to a next app —
  so the parameter was dead weight that just made the constructor look
  chainable. Drop it from call sites: `Brute::Completion::OpenRouter.new(model:
  "anthropic/claude-sonnet-4")` instead of `Brute::Completion::OpenRouter.new(app,
  model: "anthropic/claude-sonnet-4")`.

## [4.3.1] - 2026-08-23

### Added

- Failure hooks around the provider call in `Brute::Completion::OpenRouter`.
  A call that raises no longer propagates up the stack: the middleware emits
  `:llm_failure` with the turn env, then one of `:faraday_error` (for a
  `Faraday::Error`), `:open_router_server_error` (for an
  `OpenRouter::ServerError`) or `:standard_error` for anything else, each with
  the exception itself, and returns the env with no assistant message
  appended. Subscribe as you would to any other hook —
  `.on(:llm_failure) { |env| ... }`. If you relied on a provider error
  reaching your own `rescue`, re-raise from an `:llm_failure` subscriber. The
  four names are listed in `Brute::Hooks::EVENTS`.

## [4.3.0] - 2026-08-21

### Added

- `Brute::Middleware::Loop::BackgroundJobs` — a `Loop` that keeps the turn
  alive while background jobs are running. Use it outside the tool loop
  (`use Brute::Middleware::Loop::BackgroundJobs` above
  `use Brute::Middleware::Loop::ToolResult`): the inner loop ends when the
  model answers with text, and this one sends control back in for another pass
  while `env[:background_jobs]` is truthy, which is how a finished job gets
  reported. Whatever spawns the jobs — say, a middleware running a subagent in
  the background — keeps `env[:background_jobs]` current.

## [4.2.0] - 2026-08-20

### Added

- The release toolchain moved out to the
  [gem_kit-release](https://rubygems.org/gems/gem_kit-release) gem, now a
  development dependency. It registers one RubyGems command:
  `gem kit bump|changelog|deprecations|release|tag`, plus `gem kit setup`.
  Brute's own deprecations are declared with `GemKit::Deprecate` from the
  `gem_kit` gem, so `gem kit deprecations` reads them directly. The release
  half stays a development dependency: enforcing a deadline is not something a
  library should carry. On `gem_kit-release ~> 0.3`, so `gem kit release`
  refuses while anything is uncommitted and tags the release itself.

### Deprecated

- `Brute::Deprecate` — use `GemKit::Deprecate` instead, from the
  [gem_kit](https://rubygems.org/gems/gem_kit) gem, which is now a runtime
  dependency. It is the same code, extracted so other gems can use it and so
  the tooling reads one registry rather than two. `extend Brute::Deprecate`
  still works — it warns, extends `GemKit::Deprecate` for you, and aliases
  `brute_deprecate` to `deprecate` and `brute_deprecate_constant` to
  `superseded_by` — until 5.0.
- `Brute::Changelog` — use `GemKit::Release::Changelog` instead. The
  implementation stays here and keeps working; it will be removed in 5.0.

### Removed

- `bin/increment-version`, `bin/deprecations`, `bin/lint-changelog`,
  `bin/update-changelog`, `bin/release-gem` and `bin/tag-version`, superseded
  by the `gem kit` subcommands of the same names. These were repository
  scripts, not part of the gem's public API.

## [4.1.0] - 2026-08-20

### Added

- `Brute.load_agent(path)` — load an agent from a `.ru` file, the Brute
  analogue of `rackup`: `Brute.load_agent("agent.ru").start(prompt)`. The path
  defaults to `./agent.ru`. What comes back is the `AgentPipeline` itself, so
  it can be started, further `.use`d, or served through `Brute::Rack::Adapter`.
- `Brute::Completion` — a namespace for completion middlewares, the terminal
  step of a turn. Each one is a ready-made replacement for the hand-written
  `run` proc: it takes `env[:messages]`, calls one provider, and appends the
  reply back onto the log. `Brute::Completion::OpenRouter` is the first.
- `Brute::Deprecate` — the project's deprecation policy in code, built on
  `Gem::Deprecate`. `brute_deprecate` deprecates a method,
  `brute_deprecate_constant` a renamed or moved constant; both name their
  replacement and the version the old name will be removed in, and both
  register themselves so the outstanding set is queryable
  (`registry`, `pending(version)`, `upcoming(version)`). See DEPRECATIONS.md.
- `Brute::Changelog` — a parser and linter for CHANGELOG.md against
  [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Checks headings,
  dates, ordering, duplicates and section types, and answers whether a given
  version is ready to release.
- `Brute::Contrib::LogFile` — a line-oriented append-only log file that doubles
  as a work queue. `append` folds newlines so an entry is always one line;
  `pop` takes the newest line off the end, `drain` yields every line
  oldest-first and empties the file. Safe across threads (a mutex) and
  processes (an exclusive `flock`).
- `bin/deprecations`, `bin/lint-changelog`, `bin/update-changelog` — list
  outstanding deprecations, check the changelog format, and have the `claude`
  CLI write the release entry.
- `DEPRECATIONS.md` and `RELEASE.md` — the deprecation policy and the release
  process, including the versioning rules.

### Changed

- `bin/increment-version` refuses to bump onto a deprecation deadline, listing
  what is due with its source line (`--force` overrides), and points at
  `bin/update-changelog` when it is done.
- `bin/release-gem` refuses to build or push without a changelog entry for the
  version being released, or with a deprecation still due in it.
- Brute now depends on `file-tail` (used by `Brute::Contrib::LogFile`).

### Deprecated

- `Brute::Middleware::OpenRouter::Completion` — use
  `Brute::Completion::OpenRouter` instead. The old name remains a working
  subclass and warns on use; it will be removed in 5.0.

## [4.0.0] - 2026-08-16

### Added

- `Brute::Hooks` + `.on()` — lifecycle hooks on the agent builder:
  `Brute.agent.use(...).run(...).on(:before_llm) { ... }.on(:approve_tool) { ... }`.
  Emission points: `:turn_start`/`:turn_end` (AgentPipeline#start; turn_end
  fires from an ensure), `:before_llm`/`:after_llm` (around every LLM call in
  Middleware::OpenRouter::Completion), and `:before_tool`/`:approve_tool`/
  `:after_tool` around every tool execution in Middleware::ToolPipeline.
  before_tool may rewrite `:arguments` or short-circuit with a `:result`
  ("respond"); approve_tool denies on a false return (or a String, which
  becomes the denial message); after_tool may rewrite `:result`. Tool call
  payloads are {name:, arguments:, result:, events:, metadata:, turn_env:}.

- `Brute::Middleware::Skills` — loads skill objects into the turn. Discovery
  stays the caller's job (`Brute::Skill.all(cwd: Dir.pwd)`); the middleware
  puts them on `env[:skills]` for downstream middleware and tools, and mirrors
  them into `env[:metadata][:skills]` so `Middleware::SystemPrompt` renders the
  `<available_skills>` section. Place it before `Middleware::SystemPrompt`.
- `Brute::PromptTemplate` — an ERB-backed system prompt for
  `Middleware::SystemPrompt`, the open alternative to `Brute::SystemPrompt`'s
  built-in section stacks. Every keyword becomes an `attr_accessor` and an ERB
  local; proc values are re-evaluated and template files re-read on every
  prepare, so file-backed sections hot-reload between turns.
- `Brute::Prompts::Base` — provider-specific prompt text resolution
  (`section/<provider>.txt`, falling back to `section/default.txt`), named
  agent prompts, and an ERB `Context` that turns context-hash keys into
  template methods.
- `Brute::Skill.all` and `.get` accept an explicit `paths:` list alongside
  `cwd:`, and `Skill.load` takes a `source:`. Skills may now declare
  `disable-model-invocation` in their frontmatter, which hides them from the
  model while leaving them loadable by name.
- Provider usage is exposed on `env[:metadata][:last_llm_usage]` after every
  OpenRouter call, for downstream budget, iteration-limit and compaction
  accounting.

### Changed

- `AgentPipeline#start` now puts the pipeline's hook registry on `env[:hooks]`
  and always returns the env, with `:turn_end` firing from an `ensure` so it
  runs even when the turn raises.
- `Brute::Prompts::Skills` renders from an ERB template
  (`lib/brute/prompts/text/skills/default.erb`) instead of an inline heredoc,
  and the gem now ships `lib/**/*.erb`.

### Removed

- **`Brute::Skill.fmt(skills)`** — the skills section is rendered by
  `Brute::Prompts::Skills` from its ERB template instead.
- **`Brute::Skill.scan_dirs(cwd)`** — superseded by the `paths:` argument to
  `Skill.all`.

## [3.2.2] - 2026-08-14

### Fixed

- `Brute::MessageTransport::OpenRouter` now reads an `OpenRouter::Response`
  properly: it takes messages from `#choices`, symbolises roles, slices away
  provider extras (`refusal`, `reasoning`, `model`, …) that `Brute::Message`
  does not model, and unwraps OpenAI-wire tool calls
  (`{id:, type:, function: {name:, arguments: "<json>"}}`) into the flat
  `{id:, name:, arguments: Hash}` shape, parsing the JSON arguments.

## [3.2.1] - 2026-08-13

### Fixed

- `Brute::Middleware::OpenRouter::Completion` referenced `OpenRouter::*`
  unqualified, which resolved to the enclosing `Brute::Middleware::OpenRouter`
  module instead of the gem's top-level namespace. Now root-scoped (`::OpenRouter`).

## [3.2.0] - 2026-08-13

### Added

- **OpenRouter support.** `Brute::Middleware::OpenRouter::Completion` — the
  first completion middleware, a drop-in terminal app for the pipeline that
  makes the LLM call for you instead of leaving it to a hand-written `run`
  proc — plus `Brute::MessageTransport::OpenRouter`. Needs the
  `open_router_enhanced` gem, which Brute does not depend on.
- `Brute::MessageTransport::RubyOpenAI` — transport for the `ruby-openai` gem.
- `Brute::Message#has_tool_calls?` as an alias of `#tool_call?`.

### Changed

- `Brute::Middleware::ToolPipeline` accepts tool calls as either an array or
  the id-keyed hash some libraries return, and resolves tools through
  `Brute::Tools::Adapter.wrap_all`.

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

### Changed

**Migration from 3.0.0:**

- Replace `Brute.rubyllm_tools(tools)` with `Brute.tools(tools)` and
  translate the resulting adapters' `#to_h` output for your LLM
  library, or use one of the bundled `Brute::MessageTransport::*`
  adapters.
- Add your LLM library (`ruby_llm`, `llm`, `openai`, `anthropic`, …)
  to your own Gemfile — Brute no longer pulls one in.

## [3.0.0] - 2026-07-05

### Added

- Initial 3.0.0 gem release (superseded by 3.0.1 — see above).
