---
layout: default
title: The Agent Pipeline
nav_order: 1
description: 'Brute.agent returns a Rack-style builder that is also the runnable agent: chain .use and .run, then .start a turn.'
---

# The Agent Pipeline

`Brute.agent` returns a `Brute::Turn::AgentPipeline` — a subclass of `Rack::Builder` that is simultaneously the *builder* and the *agent*. You configure it by chaining, and run it with `.start`:

```ruby
agent = Brute.agent                 # => AgentPipeline
  .use(Brute::Middleware::SystemPrompt)   # => same pipeline (.use returns self)
  .run ->(env) { ... }                    # => same pipeline (.run returns self)

env = agent.start("what changed?")        # runs one turn, returns the env
```

A block form is equivalent (evaluated in the pipeline's context):

```ruby
agent = Brute.agent do
  use Brute::Middleware::SystemPrompt
  run ->(env) { ... }
end
```

## The env

`.start` seeds a plain Hash and sends it through the stack:

| Key | Value |
|---|---|
| `:messages` | the conversation log — an Array of [`Brute::Message`]({% link _core_features/messages.md %}) with role-tagging sugar (`Brute.log`) |
| `:events` | an event sink (`<<`-able); defaults to a null sink — see [Events]({% link _advanced/events.md %}) |
| `:metadata` | a scratch Hash for middleware (timing, session ids, ...) |
| `:current_iteration` | the tool-loop counter, starts at 1 |
| `:tools` | set by the `ToolPipeline` middleware on the way in |

`.start` accepts a String (becomes a `role: :user` message), a `Brute::Message`, a Hash (coerced into one), an Array (used as the log), or nothing (empty log — useful when `SessionLog` provides the history).

## The terminal `run` proc

The innermost app is the LLM call, and it is **yours**. Brute has no completion middleware and no LLM configuration — provider, model, and credentials all live in the proc, written with whatever library you like:

```ruby
run do |env|
  # 1. convert env[:messages] to your library's format   (transport.dump_all)
  # 2. make ONE completion, advertising env[:tools]
  # 3. append the response back as Brute::Message values (transport.wrap_each)
end
```

The [MessageTransport]({% link _core_features/message-transports.md %}) classes handle steps 1 and 3 for ruby_llm, llm.rb, openai and anthropic.

The proc does one completion per pass, not the whole loop — [`Loop::ToolResult`]({% link _core_features/middleware.md %}) re-invokes the stack while the model keeps calling tools, so Brute stays the turn manager.

## Slash commands

`map` registers prompt templates, expanded before the turn starts. `$ARGUMENTS` is replaced with everything after the command:

```ruby
agent = Brute.agent
  .map("/weather", "Get the weather in the following location $ARGUMENTS")
  .map("/echo") { "you said: $ARGUMENTS" }
  .run ->(env) { ... }

agent.call("/weather London")   # prompt becomes "Get the weather in the following location London"
```

## Agents from `.ru` strings and files

Because the pipeline is a `Rack::Builder`, an agent can be defined in rackup syntax and parsed at runtime:

```ruby
agent = Brute::Turn::AgentPipeline.new_from_string(<<~RU, "(inline)")
  use Brute::Middleware::SystemPrompt
  run ->(env) { env[:messages].assistant("hi") }
RU

# or from a file:
agent = Brute::Turn::AgentPipeline.parse_file("agent.ru")
agent.start("hello")
```

This is also what lets an agent [serve over HTTP]({% link _advanced/rack.md %}) — the same builder drops into a `config.ru`.

## Pipelines everywhere

`AgentPipeline` composes `Brute::Turn::Pipeline`, a thin `Rack::Builder` subclass whose `use`/`run` return `self` for chaining. The same class powers [`ToolPipeline`]({% link _core_features/tools.md %}) (tools with middleware) and [`SubAgent`]({% link _advanced/sub-agents.md %}) (agents as tools) — one mental model for the whole framework.
