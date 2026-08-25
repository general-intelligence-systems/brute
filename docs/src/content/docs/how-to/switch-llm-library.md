---
title: Switch LLM Libraries
description: Swap the library behind your agent's run proc — or add one with no
  shipped transport — without touching the middleware stack.
sidebar:
  order: 6
---

Everything about the LLM lives in your terminal `run` proc, so switching libraries is a change to that proc and nothing else: same middleware stack, same tools, same session log. The [MessageTransport](../message-transports/) for each library handles the translation at the boundary.

## Switch to a library with a shipped transport

Four transports ship with the gem:

| Transport | Library |
|---|---|
| `MessageTransport::RubyLLM` | [ruby_llm](https://rubyllm.com) |
| `MessageTransport::LLM` | [llm.rb](https://github.com/llmrb/llm.rb) |
| `MessageTransport::OpenAI` | [openai](https://github.com/openai/openai-ruby) |
| `MessageTransport::Anthropic` | [anthropic](https://github.com/anthropics/anthropic-sdk-ruby) |

Each absorbs that provider's quirks (Anthropic's top-level `system_`, OpenAI's JSON-string tool arguments, ruby_llm's id-keyed tool-call hash), so the swap is mechanical. Going from the ruby_llm example to the anthropic gem means replacing only the `run` proc:

```ruby
require "anthropic"

agent = Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::DefaultToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    transport = Brute::MessageTransport::Anthropic
    client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])

    response = client.messages.create(
      model:      "claude-opus-4-8",
      max_tokens: 16_000,
      system_:    transport.system_text(env[:messages]),
      messages:   transport.dump_all(env[:messages]),
      tools:      anthropic_tools(env[:tools]),   # adapter.to_h -> API shape
    )

    transport.wrap_each(response) { |m| env[:messages] << m }
  end
```

The tool-advertising helper changes too — it reshapes `adapter.to_h` into the new library's tool format — but the tools themselves (`Brute::Tools::ALL`) do not.

The repo ships this exact agent four times over in `examples/ruby-llm/`, `examples/llm-rb/`, `examples/openai/`, and `examples/anthropic/`. Diff their `main.rb` files to see precisely what changes: the `run` proc and the tool helper, nothing else.

## Add a library with no shipped transport

Subclass `Brute::MessageTransport` and override `.dump` (outbound) and `#wrap` (inbound); the base class handles flattening and enumerator plumbing:

```ruby
class MyTransport < Brute::MessageTransport
  def self.dump(message)
    # Brute::Message -> your library's request message
  end

  private

  def wrap(message)
    # your library's response message -> Brute::Message
  end
end
```

Two conventions keep it optional like the shipped ones:

- Reference the library lazily inside those methods — no top-level `require` — so users who don't use it pay nothing.
- Accept whatever the proc got back in `wrap_each` (a single message, an array, or anything responding to `#messages`).

See [Message Transports](../message-transports/) for the full four-entry-point API.
