---
title: Why Brute Owns No LLM Library
description: The design decision behind bring-your-own-LLM — the transport seam,
  duck-typed messages, and what it costs.
sidebar:
  order: 8
---

Brute has no completion middleware, no provider configuration, and no dependency on any LLM library. Provider, model, and credentials live entirely inside the terminal `run` proc you write. This is a deliberate design decision, not an omission.

## The problem it avoids

An agent framework that ships with an LLM library baked in makes three promises it can't keep: that its bundled library supports your provider best, that its release cadence matches that library's, and that its abstraction over "a chat completion" fits your model's features. Every new provider API — reasoning traces, structured output, server-side tools — then waits on the framework to grow a matching wrapper.

## The seam: two small conversions

Calling an LLM is easy with any library; translating message formats is the tedious part. So Brute owns exactly the translation, at a boundary two methods wide:

```
outbound   Brute::Message log   ── dump_all ──▶   the library's request format
inbound    the library response ── wrap_each ──▶  Brute::Message
```

That's `Brute::MessageTransport` — see [Message Transports](../message-transports/). Four transports ship with the gem, each referencing its library lazily so none of them cost anything unless used.

The inbound half works because of the other half of the design: `Brute::Message` is an immutable `Data` value with four fields (`role`, `content`, `tool_calls`, `tool_call_id`), and nothing in Brute's stack calls beyond those plus `#to_h`. Any object exposing them can ride in `env[:messages]` — including a library's own message objects, if you'd rather not convert at all.

## What you get

- **No version lockstep** — upgrade ruby_llm when *it* releases, not when the framework catches up.
- **Optional everything** — the gem installs without any LLM dependency; tests and CI don't need API keys.
- **One agent, many models** — the same middleware stack serves local Ollama in dev and Anthropic in prod by swapping one proc.
- **Escape hatch as first-class API** — supporting an unlisted library is ~20 lines (see [Switch LLM Libraries](../switch-llm-library/)), not a feature request.

## What it costs

Honesty requires the trade-offs: your `run` proc is real code, so a minimal agent is a few lines longer than a framework where `Agent.new(model: "...")` just works, and tool advertising means reshaping `adapter.to_h` into your library's format yourself. Brute bets that agents are long-lived enough to prefer owning the LLM boundary over renting one.
