---
layout: default
title: Serving over HTTP
nav_order: 5
description: 'Brute::Rack::Adapter wraps any agent as a Rack app, so it serves over HTTP behind Falcon, Puma, or any Rack server.'
---

# Serving over HTTP

An `AgentPipeline` is a builder, not a Rack app — you `.start` it. `Brute::Rack::Adapter` bridges the gap: it wraps an agent as a Rack app (`call(env) → [status, headers, body]`), so any agent drops into a `config.ru` and serves over HTTP behind Falcon, Puma, or anything Rack.

```ruby
# config.ru
require "brute"

agent = Brute::Turn::AgentPipeline.parse_file("examples/agents/brute.ru")
run Brute::Rack::Adapter.for(agent)
```

```sh
$ curl -d 'What files are here?' localhost:9292
$ curl -H 'content-type: application/json' -d '{"prompt":"hi"}' localhost:9292
$ curl 'localhost:9292/?prompt=hi'
```

## How the prompt is extracted

The adapter looks for the prompt in four places, most explicit first:

1. a `?prompt=` query parameter,
2. a JSON body — a `prompt` / `message` / `input` key of an object, or a bare JSON string,
3. a form-encoded `prompt=` field,
4. otherwise the raw request body *is* the prompt.

A missing prompt is a `400`; anything the turn raises is a `500`. Responses are content-negotiated: a JSON request (or `Accept: application/json`) gets `{"response": "..."}`, everything else gets `text/plain`.

## The two transforms

The whole adapter is two pure functions wired around one `agent.start`:

```
env    -> prompt string             (the request half)
output -> [status, headers, body]   (the response half)
```

The agent's answer is the last message it appended to the log. Anything that responds to `#start(prompt) -> env` works — an `AgentPipeline`, a [`SubAgent`]({% link _advanced/sub-agents.md %}), or any turn-shaped callable — so you can serve a sub-agent directly if that's the unit you want to expose.

## Agents as `.ru` files

`parse_file` reads an agent defined in rackup syntax, so the HTTP entry point and the agent definition can live in one versioned file:

```ruby
# examples/agents/brute.ru
use Brute::Middleware::SystemPrompt
use Brute::Middleware::Loop::ToolResult
use Brute::Middleware::MaxIterations
use Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL
run ->(env) { ... }   # your LLM call
```

The repo ships `examples/agents/brute.ru` (the agent) and `examples/agents/config.ru` (the `Brute::Rack::Adapter.for(agent)` wrapper) as a working pair — run it with `rackup examples/agents/config.ru` or `falcon serve -c config.ru`.

This is the same builder covered in [The Agent Pipeline]({% link _core_features/agents.md %}) — serving it over HTTP adds no new concepts, just a Rack wrapper.
