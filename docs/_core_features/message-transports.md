---
layout: default
title: Message Transports
nav_order: 3
description: 'The MessageTransport pattern translates between Brute messages and any LLM library. Ships with transports for ruby_llm, llm.rb, openai, and anthropic.'
---

# Message Transports

A `MessageTransport` is the seam that makes Brute framework-agnostic. Calling an LLM is trivial with any library, so Brute has no completion middleware — the terminal `run` proc makes the call, and a transport translates at the boundary in both directions:

```
outbound   Brute::Message log   ── .dump_all ──▶   the library's request format
inbound    the library response ── .wrap_each ──▶  Brute::Message
```

```ruby
# outbound: hand your library a request it understands
messages = Brute::MessageTransport::RubyLLM.dump_all(env[:messages])
response = provider.complete(messages, tools:, model:)

# inbound: fold the reply back into the Brute log
Brute::MessageTransport::RubyLLM.wrap_each(response) do |message|
  env[:messages] << message
end
```

## Shipped transports

Four transports ship with the gem. Each references its library lazily — you `require` the gem, Brute does not depend on it.

| Transport | Library | Absorbs |
|---|---|---|
| `MessageTransport::RubyLLM` | [ruby_llm](https://rubyllm.com) | ruby_llm's id-keyed `tool_calls` hash ↔ flat list |
| `MessageTransport::LLM` | [llm.rb](https://github.com/llmrb/llm.rb) | `LLM::Function::Return` for tool results; provider-native tool-call extras |
| `MessageTransport::OpenAI` | [openai](https://github.com/openai/openai-ruby) | choice unpacking; JSON-string tool arguments |
| `MessageTransport::Anthropic` | [anthropic](https://github.com/anthropics/anthropic-sdk-ruby) | top-level `system_:`; `tool_use`/`tool_result` content blocks; alternating roles |

Each has a matching runnable agent in the repo: `examples/ruby-llm/`, `examples/llm-rb/`, `examples/openai/`, `examples/anthropic/`. Only the `run` proc differs between them.

## The API

Every transport is a subclass of `Brute::MessageTransport` with four entry points:

```ruby
transport.dump_all(messages)          # class method — whole log → library format
transport.dump(message)               # class method — one message → library format
transport.wrap_each(result) { |m| }   # class or instance — library response → Brute::Message
transport.new(result).messages        # the response flattened to a list, pre-wrap
```

`wrap_each` normalizes whatever the proc got back — a single message, an array, or a transcript-shaped object (anything responding to `#messages`) — and yields each as a `Brute::Message`. Without a block it returns an Enumerator.

## Provider-specific shapes

The transports exist because providers disagree on message shape, and Brute shouldn't. Two examples of what a transport absorbs so your `run` proc doesn't have to:

**Anthropic** puts the system prompt in a top-level parameter, not the messages array, and folds tool results into `user` turns as content blocks:

```ruby
transport = Brute::MessageTransport::Anthropic
client.messages.create(
  model:      "claude-opus-4-8",
  max_tokens: 16_000,
  system_:    transport.system_text(env[:messages]),   # extracted from :system messages
  messages:   transport.dump_all(env[:messages]),      # tool results folded into user turns
  tools:      anthropic_tools(env[:tools]),
)
```

**OpenAI** delivers tool-call arguments as JSON *strings*; the transport parses them into a Hash inbound and re-encodes them outbound, so `Brute::ToolCall#arguments` is always a real Hash.

## Writing your own

To support a library that has no shipped transport, subclass `Brute::MessageTransport` and override `#wrap` (inbound) and `.dump` (outbound). The base class handles flattening and the enumerator plumbing:

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

Reference the library lazily inside those methods (don't `require` it at the top of the file) so the transport stays optional, matching the shipped ones.
