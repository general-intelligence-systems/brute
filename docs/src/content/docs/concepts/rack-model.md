---
title: The Rack Model for Agent Turns
description: Why an agent turn is a Rack request — an env flowing through a middleware
  stack toward a terminal app — and how the pieces compose.
sidebar:
  order: 6
---

Brute treats an agent turn the way Rack treats an HTTP request. In Rack, a request becomes an `env` hash that flows down through middleware toward a terminal application, and the response flows back up through the same layers. In Brute, the turn is the request, `env` is the same kind of hash, and the terminal app is your LLM call:

```
.start(prompt)
  │
  ▼  env flows down ──────────────────────────────────▶
  SessionLog      load history from disk
  SystemPrompt    prepend the system message
  Loop::ToolResult   ┐ re-invoke while the model
  MaxIterations      │ keeps calling tools
  ToolPipeline       ┘ advertise tools; execute calls
  run ->(env) { }    ← YOUR one LLM completion
  ▲  results flow back up ◀───────────────────────────
```

The middleware is the agentic machinery — persistence, prompting, the tool loop, iteration guards — and it is composable: use what you want, omit what you don't. Nothing in the stack knows which LLM library sits at the bottom.

## The contract

A middleware is any object constructed with `(app, **opts)` that responds to `call(env)` and calls `@app.call(env)` exactly once — before for "on the way in" work, after for "on the way out" work:

```ruby
class MyMiddleware
  def initialize(app, **opts) = (@app = app)
  def call(env)
    # ... before the rest of the stack ...
    @app.call(env)
    # ... after ...
    env
  end
end
```

Because every layer sees the same mutable `env`, middleware communicate by leaving values in it: the system prompt appears as a message, tools as `env[:tools]`, timing and session ids in `env[:metadata]`. Files are numeric-prefixed by stack position (`002_session_log.rb`, `070_tool_pipeline.rb`) — lower numbers sit further out.

## The loop is a layer, not the framework

The agentic loop — call the model, run its tools, call again — is itself just middleware (`Loop::ToolResult`). It is a `do`-while: the inner stack always runs once, then the loop re-invokes while the last message is a `:tool` result (or until `env[:should_exit]` or `MaxIterations` ends it). Your `run` proc does *one completion per pass*, never the whole loop — Brute stays the turn manager.

This placement is what makes the framework small: there is no loop object to configure, no callback API. A different loop is a different condition proc:

```ruby
use Brute::Middleware::Loop, ->(env) { env[:messages].last&.role == :tool }
```

## Order encodes policy

Middleware ordering is not decoration — it is where behaviour lives. `SessionLog` goes outermost so history loads before anything else and the whole turn persists after. `Loop::ToolResult` sits above `ToolPipeline` so the loop re-runs after each tool batch, with `MaxIterations` between them as the guard. Compaction sits *inside* the loop so it runs before every model call, not once per turn.

The same principle scales down into sub-pipelines: `ToolPipeline` builds a single tool out of middleware (validate → snapshot → execute), and `CompactionPipeline` builds a compactor out of strategies ordered cheapest-first — a layer that already got under target never calls the next, so stack order *is* the cost policy. One mental model all the way down.
