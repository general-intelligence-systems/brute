# Changelog

All notable changes to Brute are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [6.0.1] - 2026-08-28

### Changed

- **A traced event carries the trace, not its id.** The last extra on every
  event emitted through a `Brute::Hooks::Trace` is now the trace itself, where
  6.0.0 passed `trace.id`. A subscriber that wants the call's identity asks it
  for `#id`; one that wants anything else about the call already has it,
  because a trace *is* the env it wrapped (`SimpleDelegator`) — so a tracing
  provider can read the messages, the metadata and the usage off the same
  object it hangs the generation on.

  ```ruby
  # 6.0.0
  agent.on(Brute::Hooks::LLM_END_EVENT) { |env, id| record(id) }

  # 6.0.1
  agent.on(Brute::Hooks::LLM_END_EVENT) { |env, trace| record(trace.id) }
  ```

  Subscribers written against 6.0.0 that treat the last extra as an id must
  take `#id` off it.

## [6.0.0] - 2026-08-27

The events engine is rewritten to make way for tracing providers — Langfuse,
OpenTelemetry, anything that wants a tree rather than a stream. An event could
say what happened but not what it happened *inside*: the env is shared by the
whole turn and a middleware knew only the registry, so there was nothing to
hang a generation off. Every event now belongs to a trace, and traces nest —
a completion's inside its layer's, a layer's inside the turn's.

### Added

- `Brute::Hooks::Trace`. Every start/duration/end set is wrapped in
  `emit_trace`, and the id of the trace an event belongs to reaches subscribers
  as the last extra. Traces nest by delegation — a completion's inside its
  layer's, a layer's inside the turn's — which is what a tracing provider needs
  to hang a generation off the call that asked for it.

- A failure event per set: `TURN_FAILURE_EVENT`, `MIDDLEWARE_FAILURE_EVENT`,
  `COMPACT_FAILURE_EVENT`, `TOOL_FAILURE_EVENT`, beside the existing
  `LLM_FAILURE_EVENT`. Each is emitted from inside its own trace, so a failure
  is attributed to the call that failed.

- `COMPACT_START_EVENT`, and `CONTENT_EVENT` / `REASONING_EVENT` for streaming,
  `TOOL_CALLS_EVENT` for the batch a completion asked for.

### Changed

- **Lifecycle events are named as sets.** Every phase of a run now reads
  `*_START` / `*_DURATION` / `*_FAILURE` / `*_END`, so a subscriber can be
  written against the shape rather than against five spellings of the same
  idea.

  | Was | Is |
  | --- | --- |
  | `ENTER_EVENT`, `DURATION_EVENT`, `EXIT_EVENT` | `MIDDLEWARE_START_EVENT`, `MIDDLEWARE_DURATION_EVENT`, `MIDDLEWARE_END_EVENT` |
  | `BEFORE_LLM_EVENT`, `AFTER_LLM_EVENT` | `LLM_START_EVENT`, `LLM_END_EVENT` |
  | `BEFORE_TOOL_EVENT`, `APPROVE_TOOL_EVENT`, `AFTER_TOOL_EVENT` | `TOOL_START_EVENT`, `TOOL_APPROVE_EVENT`, `TOOL_END_EVENT` |
  | `COMPACTED_EVENT` | `COMPACT_END_EVENT` |

- **Emitting moved onto the env.** A layer no longer has an `emit` bolted onto
  it: what a pipeline is called with is wrapped in a `Brute::Hooks::Trace`,
  which is the env (`SimpleDelegator`) and answers `emit`. `bind_emitter` is
  gone, and with it the "was given a lambda" warning — a lambda is handed the
  same env as anything else and can emit from it.

  ```ruby
  def call(env)
    env.emit_trace do |env|
      env.emit(LLM_START_EVENT)
      env.emit(LLM_DURATION_EVENT) { response = complete(env) }
      env.emit(LLM_END_EVENT)
    end
  end
  ```

- `Brute::Turn::Pipeline.new` takes `hooks:`, so a nested pipeline either owns
  a registry or reports to the one that built it. One `Registry` per agent.

- **Licence changed from MIT to Apache-2.0.** The gemspec now advertises
  `Apache-2.0`, so downstream projects tracking upstream licences need to
  refresh their attribution. Apache-2.0 adds an explicit patent grant that MIT
  left implicit; nothing about redistribution or modification changes in
  practice.

### Removed

- **`env[:events]` and its sink.** `Brute::Turn::Pipeline::NullSink` and
  `Brute::Middleware::EventHandler` are gone, along with every `events:`
  keyword argument — `AgentPipeline#start`, `ToolPipeline#call` and
  `CompactionPipeline#compact` no longer accept one. What was pushed to the
  sink is emitted through the hooks instead.

- `Brute::Middleware::CompactionCheck` and `Brute::Middleware::ToolPipeline`,
  deprecated since 5.0 and due in 6.0. Use
  `Brute::Middleware::DefaultCompactionPipeline` and
  `Brute::Middleware::DefaultToolPipeline`.

- `Brute::Hooks.new`. It was a module pretending to be a class; build the
  registry it built — `Brute::Hooks::Registry.new`.

## [5.1.0] - 2026-08-25

### Added

- `Brute::Middleware::DefaultCompactionPipeline`, which compacts a conversation
  once it fills too much of the model's window. It owns the *when* — estimating
  the size before each call and deriving the target — and hands the *what* to a
  compactor.

  ```ruby
  use Brute::Middleware::Loop::ToolResult
  use Brute::Middleware::DefaultCompactionPipeline,
    window:     200_000,
    summariser: Brute::Completion::OpenRouter.new(config: { access_token: key })
  use Brute::Middleware::DefaultToolPipeline, tools: tools
  ```

  It belongs inside the tool loop, so it runs before every call rather than
  once a turn. Sizing anchors on what the provider counted for the last call
  and measures locally only what has landed since. Pass `compactor:` to
  replace the ladder it wires by default.

- `Brute::Turn::CompactionPipeline`, a compactor built out of middleware — the
  compaction counterpart of `Brute::Turn::ToolPipeline`, composed the same way.
  The stack order is the policy: a layer that got the conversation under target
  does not call the next, so the free strategies sit at the top and the
  terminal app — the only thing that spends money — is reached only when they
  could not get there.

  ```ruby
  Brute::Turn::CompactionPipeline.new do
    use Brute::Compaction::Middleware::ToolResults,   keep_steps: 1
    use Brute::Compaction::Middleware::SlidingWindow, keep_steps: 2
    run Brute::Compaction::Summarize.new(chat_generator)
  end
  ```

  The conversation rides on `env[:conversation]`, leaving `env[:messages]` to
  mean what it means to every other terminal app: the prompt down, the reply
  back.

- `Brute::Compaction::Middleware`, the strategies that are layers.
  `ToolResults` rewrites older tool output in place so every call keeps the
  result answering it; `SlidingWindow` drops the oldest complete turns, then
  the current task's oldest steps, leaving a note where they were. Both are
  free and neither calls a model. `Compaction::Middleware::Strategy` is the base, and it
  owns the rules every strategy keeps: asked only while over target, and taken
  only when it actually made the conversation smaller.

- `Brute::Compaction::Summarize`, the strategy of last resort and the one that
  ends a pipeline. It replaces stretches with summaries of them round after
  round, in four tiers — oldest historical turns, then historical summaries
  combined, then the current task's oldest steps, then its own summaries. It
  stops at the last round that worked, so a generator that answers nothing
  usable, a summary no smaller than what it replaced, or a call that raised
  all leave the conversation as the previous round left it.

- `Brute::Compaction`, what every strategy needs: `Transcript` for the grouping
  that keeps a tool call with its results, and an injectable token counter on
  `env[:token_counter]` so a strategy weighs the conversation the same way the
  trigger did.

- `Brute::TokenCounter`, how big a conversation is. A counter answers
  `count(messages, tools: nil)` — the tools because their schemas ride in
  every request, so an agent carrying a dozen of them is spending context
  before anyone has said a word. `Approximate` divides the rendered text by a
  characters-per-token ratio and needs no dependency; `Tiktoken` encodes it
  with `tiktoken_ruby`, required the first time it is asked rather than at
  boot.

  ```ruby
  Brute::TokenCounter.estimate(env)   # what the turn costs right now
  ```

  `estimate` trusts what the provider counted when it answered and measures
  locally only what has landed since — and never the schemas on that path,
  because the reported total already covers them.

- `Brute::Eval`, evaluating an assembled agent rather than testing a layer.
  A `Case` says what was said, the world it was said in, and what must be true
  of the turn afterwards — a call that was made, a call that was not, the order
  two came in, a word the answer must contain, a budget it must stay inside.

  ```ruby
  exit(Brute::Eval::Suite.new(agent: "agent.ru", cases: CASES).run)
  ```

  Everything it observes comes off the agent's own hooks, so the agent under
  evaluation is the agent that ships. Tool results are stubbed on
  `:before_tool`, which answers a call without executing it, and where a case
  wakes up is `Brute::Eval::World`, which a deployment subclasses.

- `Brute::Env`, asked of the turn env itself: `#reply` is the last message and
  only when the assistant wrote it, `#has_reply?` whether there was one. A turn
  that only ran tools, or whose provider failed, ends on something else.

- `:compacted`, emitted with `{context:, before:, after:}` when a turn's conversation is
  rewritten — `context:` is the anchored estimate that triggered it, `before:`
  and `after:` the conversation on its own. Compaction is lossy and the
  pipeline keeps no record, so an application that wants one preserves it
  here.

  ```ruby
  agent.on(:compacted) { |env, payload| archive(env, payload) }
  ```

- `:compact_duration`, the timed event around the attempt, so the compactor
  that spends a model call is visible alongside `:llm_duration` and
  `:tool_duration`.

  A compactor that raises is treated as one that declined: the failure goes
  onto `env[:events]` as `{type: :error}` and the turn carries on with the
  context it has.

### Changed

- `Brute::Middleware::ToolPipeline` is now
  `Brute::Middleware::DefaultToolPipeline`. The middleware is one particular
  wiring of tool dispatch, and the name now says so — leaving
  `Brute::Turn::ToolPipeline` as the mechanism you compose when that wiring is
  not what you want. The pairing is the same for compaction:
  `DefaultCompactionPipeline` and `Turn::CompactionPipeline`.

  ```ruby
  use Brute::Middleware::DefaultToolPipeline, tools: tools   # was ToolPipeline
  ```

  The old name still works, deprecated until 6.0 — see below.

### Deprecated

- `Brute::Middleware::ToolPipeline` — use
  `Brute::Middleware::DefaultToolPipeline` instead. The old name remains a
  working subclass and warns on use; it will be removed in 6.0.

- `Brute::Middleware::CompactionCheck` — use
  `Brute::Middleware::DefaultCompactionPipeline` instead. The old name keeps
  passing the turn through and compacting nothing, which is all it ever did,
  and warns on use; it will be removed in 6.0. It is deliberately *not* a
  subclass of its replacement: inheriting would make a layer that gave up
  nothing suddenly start giving up context, and a deprecation warns about a
  name rather than changing what runs under it. Its inner `Compactor` class
  has no counterpart — a strategy answering `#compact(messages, target:)`
  replaces it, and code calling `should_compact?` has to move now.

## [5.0.5] - 2026-08-24

### Added

- `Brute::Middleware::SlashCommands`, the head of every agent chain — put
  there by the builder, not by a `use` anyone writes. It runs the first of
  `env[:commands]` whose check passes on the newest user message, before the
  rest of the stack.

- `env[:commands]`, the registry `start` carries into every turn, so anything
  below the head can see what was mapped.

### Changed

- **Breaking.** `AgentPipeline#map` no longer registers a prompt template. It
  registers a command against what the room just said: whatever it is given
  becomes a check — a function of the newest message answering true or false —
  and its block is a middleware, run before the rest of the stack.

  ```ruby
  Brute.agent
    .map("/compact") { |env| ... }              # ^\/compact.* and what rides after
    .map(/\Aplease compact/i) { |env| ... }     # a Regexp is evaluated
    .map(->(said) { said.length > 10_000 }) { |env| ... }
  ```

  Checks are tried in registration order and the first to pass runs. Only a
  user message is offered to them. A String registered without its slash grows
  one, as before.

  A block that rewrote the prompt through a template now does it directly:

  ```ruby
  map("/weather") { |env| env[:messages].last.content = "..." }
  ```

- `AgentPipeline#to_app` (and `#build`) returns the chain with
  `Brute::Middleware::SlashCommands` at its head rather than the chain itself.

### Removed

- The two-argument form of `AgentPipeline#map` — `map("/weather", "... $ARGUMENTS")`
  — and its `$ARGUMENTS` substitution, along with the `generate_map` override.
  They could not survive: the layer they built was written against a prompt
  String while `start` hands the built app an env, so `start("/weather London")`
  split the env's `to_s`, matched nothing, and left the command in the log
  verbatim. Templates only ever expanded through `agent.call("a string")`, which
  bypasses the turn, its hooks and its message log. Rack's `generate_map` also
  builds a sub-*Builder* per entry (`self.class.new(default_app, &block)`),
  which runs a command's own block at build time — harmless for a zero-arity
  template block, fatal for one taking `|env|`.

## [5.0.4] - 2026-08-24

### Security

- A new runtime dependency, `json >= 2.21.2`, on the gemspec. Brute does not
  use json directly — activesupport, async's console and faraday each pull it
  in — but nothing in that chain requires a version above the use-after-free in
  the resumable parser on a truncated stream, so the floor is declared here.
  Installing or updating Brute now raises json for you; the dependency can go
  once the parents require the fixed version themselves.

- `websocket-driver >= 0.8.2` (denial of service on a malformed `Host` header)
  in the Gemfile's optional `browser` group, which only the
  `examples/ports/browser-agent` example uses. This one is not a gem
  dependency and does not reach an app installing Brute.

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

## [5.0.2] - 2026-08-24

### Removed

- `Brute::Completion.async_faraday!`, and with it the runtime dependency on
  `async-http-faraday`. 5.0.0 had `Completion::OpenRouter`, `Completion::RubyLLM`
  and `Completion::LangChain` call it after requiring their provider gem, to
  point Faraday's default adapter at async-http for persistent connections and
  HTTP/2. Choosing the HTTP adapter is not a decision a completion middleware
  should be making for the host app, so it is gone: the completions no longer
  touch `Faraday.default_adapter`, and Brute no longer pulls in async-http.
  Faraday falls back to Net::HTTP, which works under Async but opens a fresh
  connection per request; an app that wants the old behaviour requires
  `async/http/faraday/default` itself (and adds `async-http-faraday` to its own
  Gemfile).

  A public name removed outside a major version, against the usual rule: 5.0.0
  shipped the same day, so nothing has had the chance to depend on it.

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
