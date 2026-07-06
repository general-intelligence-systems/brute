---
layout: default
title: brute
nav_order: 1
description: 'A framework-agnostic coding agent for Ruby. Rack-style middleware pipelines for agent turns, built-in tools, session persistence — bring your own LLM library.'
permalink: /
---

# brute

A framework-agnostic coding agent for Ruby — Rack-style middleware pipelines for agent turns, a full set of coding tools, and session persistence. Bring your own LLM library.
{: .fs-6 .fw-300 }

<div class="hero-actions">
  <a href="{% link _getting_started/getting-started.md %}" class="btn btn-primary fs-5 mb-4 mb-md-0 mr-2">Get started</a>
  <a href="https://github.com/general-intelligence-systems/brute" class="btn fs-5 mb-4 mb-md-0 mr-2">GitHub</a>
</div>

Brute treats an agent turn the way Rack treats an HTTP request: an `env` hash flowing through a middleware stack toward a terminal app. The middleware handles the agentic machinery — the tool loop, session persistence, the system prompt, iteration guards. The terminal app is a proc **you** write with whatever LLM library you prefer: [ruby_llm](https://rubyllm.com), [llm.rb](https://github.com/llmrb/llm.rb), the official [openai](https://github.com/openai/openai-ruby) or [anthropic](https://github.com/anthropics/anthropic-sdk-ruby) gems, or raw HTTP. Brute depends on none of them.

## Quick start

```ruby
require "brute"
require "ruby_llm"

agent = Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    # The LLM call — yours, with your library. A MessageTransport
    # translates between Brute's message format and the library's.
    response = provider.complete(
      Brute::MessageTransport::RubyLLM.dump_all(env[:messages]),
      tools: rubyllm_tools(env[:tools]), model: model,
    )
    Brute::MessageTransport::RubyLLM.wrap_each(response) { |m| env[:messages] << m }
  end

agent.start("What files are in the current directory?")
```

The proc makes ONE completion per pass; the `ToolPipeline` middleware executes whatever tools the model called, and `Loop::ToolResult` sends the results back down the stack until the model answers with text. Brute is the turn manager — the LLM library is just a client.

Head to [Getting Started]({% link _getting_started/getting-started.md %}) for a complete runnable walkthrough.

## What's here

- **Core Features** — the [agent pipeline]({% link _core_features/agents.md %}) (`Brute.agent`, `.use`, `.run`, `.start`), the [middleware catalog]({% link _core_features/middleware.md %}), Brute's [message format]({% link _core_features/messages.md %}), the [MessageTransport pattern]({% link _core_features/message-transports.md %}) with shipped transports for four LLM libraries, and the [tool system]({% link _core_features/tools.md %}).
- **Advanced** — [sub-agents]({% link _advanced/sub-agents.md %}) (agents as tools), [session persistence]({% link _advanced/sessions.md %}), [skills]({% link _advanced/skills.md %}), [events]({% link _advanced/events.md %}), and [serving agents over HTTP]({% link _advanced/rack.md %}).
- **Examples** — [runnable agents]({% link _examples/examples.md %}), including the same agent on all four supported LLM libraries.

## Design principles

1. **No LLM dependency.** `brute.gemspec` names no LLM library. The terminal `run` proc owns provider, model, and credentials.
2. **Plain data.** The conversation log is an `Array` of `Brute::Message` — an immutable `Data` value with `role`, `content`, `tool_calls`, `tool_call_id`. Anything that duck-types those methods rides along.
3. **Middleware all the way down.** Turns are pipelines; tools can be pipelines; even the event stream is a stack of handlers. If you know Rack, you know Brute.
