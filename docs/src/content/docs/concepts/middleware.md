---
title: Middleware
description: The catalog of built-in turn middleware — the agentic machinery you compose
  around your LLM call.
sidebar:
  order: 5
---

A turn is a Rack-style pipeline: middleware wraps the terminal `run` proc, each layer seeing the `env` on the way in and again on the way out. You compose the machinery you want and omit what you don't.

A middleware is any object constructed with `(app, **opts)` that responds to `call(env)` and calls `@app.call(env)`. The convention:

```ruby
class MyMiddleware
  def initialize(app, **opts) = (@app = app)
  def call(env)
    # ... before ...
    @app.call(env)
    # ... after ...
    env
  end
end
```

Files are numeric-prefixed by stack position (`002_session_log.rb`, `070_tool_pipeline.rb`) — lower numbers sit further out.

## The catalog

| Middleware | Role |
|---|---|
| `SessionLog` | Loads conversation history from a JSONL file on the way in; persists the whole turn on the way out. Outermost. See [Sessions](../sessions/). |
| `SystemPrompt` | Prepends a `:system` message (unless one already exists). Defaults to `Brute::SystemPrompt.default`; pass a custom one for specialized agents. |
| `Loop::ToolResult` | The agentic loop. Re-invokes the inner stack while the last message is a `:tool` result, bumping `current_iteration`. Stops on a text answer or `should_exit`. |
| `Checkpoint` | Durable execution. Snapshots the conversation to an append-only JSONL chain after every pass through the loop (one checkpoint per LLM call + tool batch). `resume: :latest` resumes a crashed turn; `resume: "<id>"` time-travels to (and forks from) any snapshot. Sits just inside `Loop::ToolResult`. |
| `MaxIterations` | Guards against runaway loops. When `current_iteration` exceeds the cap (default 100), injects a "Maximum iterations reached" user message so the loop exits naturally. |
| `ToolPipeline` | Advertises tools on `env[:tools]` going in; executes the model's tool calls coming out. See [Tools](../tools/). |
| `Summarize` | Runs one final tool-free completion after the loop, so the agent ends on a clean text answer. |
| `EventHandler` | Wraps `env[:events]` in a handler class (e.g. terminal output). See [Events](../events/). |
| `Question` | Interactive-question plumbing (works with the `question` tool). |
| `DefaultCompactionPipeline` | Compacts the conversation once it fills too much of the model's window. Owns *when*; hands *what goes* to a compactor. Sits inside `Loop::ToolResult`, so it runs before every call. |
| `DefaultCompactionPipeline` | The same, with the usual ladder already wired. |

A compactor is anything answering `#compact(messages, target:)`.
`Brute::Turn::CompactionPipeline` builds one out of middleware, the way
`Brute::Turn::ToolPipeline` builds a tool out of middleware — the free
strategies (`Brute::Compaction::Middleware::ToolResults`, `::SlidingWindow`) are
`use` layers, and `Brute::Compaction::Summarize`, the one that costs money, is
the `run`. A layer that got under target never descends, so the stack order is
the policy.

## Brute::Contrib

Optional extras live outside `Brute::Middleware`, which is reserved for what
an agent turn actually needs. OpenTelemetry is the current example, and it is
not middleware at all: telemetry only ever observes, so it subscribes.

```ruby
Brute::Contrib::Otel.subscribe(agent)   # spans, usage, tool events
```

## Loop::ToolResult

The standard agentic loop is a `do`-while: the inner app always runs once, and the condition is checked after each pass.

```ruby
use Brute::Middleware::Loop::ToolResult
```

Its condition: continue while `env[:messages].last.role == :tool` and `env[:should_exit]` is unset. The generic `Brute::Middleware::Loop` takes any proc or block condition if you need a different loop:

```ruby
use Brute::Middleware::Loop, ->(env) { env[:messages].last&.role == :tool }
```

## A typical stack

```ruby
Brute.agent
  .use(Brute::Middleware::EventHandler, handler_class: TerminalOutput)
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::DefaultToolPipeline, tools: Brute::Tools::ALL)
  .run ->(env) { ... }
```

Order matters: `SessionLog` outermost so history is loaded before anything else and the whole turn is persisted after; `Loop::ToolResult` above `ToolPipeline` so the loop re-runs after each tool batch; `MaxIterations` between them as the guard.
