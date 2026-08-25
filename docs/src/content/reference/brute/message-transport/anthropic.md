---
title: "Brute::MessageTransport::Anthropic"
description: "MessageTransport for the official anthropic gem (https://github.com/anthropics/anthropic-sdk-ruby)."
---


```ruby
module Brute::MessageTransport
  class Anthropic < Brute::MessageTransport
  end
end
```

[`MessageTransport`](/brute/reference/brute/message-transport/) for the
official anthropic gem (https://github.com/anthropics/anthropic-sdk-ruby).
[`Brute`](/brute/reference/brute/) does not require it — you do:


```
require "anthropic"

client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
response = client.messages.create(
  model:      "claude-opus-4-8",
  max_tokens: 16_000,
  system_:    Brute::MessageTransport::Anthropic.system_text(env[:messages]),
  messages:   Brute::MessageTransport::Anthropic.dump_all(env[:messages]),
  tools:      ...,
)
Brute::MessageTransport::Anthropic.wrap_each(response) { |m| env[:messages] << m }
```

Anthropic's [`Messages`](/brute/reference/brute/messages/) API differs from
chat-completions-shaped APIs in two ways this transport absorbs: the system
prompt is a top-level parameter (not a message), and tool results are content
blocks inside a user message — consecutive tool results are folded into one
user turn so roles keep alternating.

## Class Methods

### self.dump

```ruby
dump(message)
```

[`Brute::Message`](/brute/reference/brute/#message) -> an
[`Anthropic`](/brute/reference/brute/message-transport/anthropic/) message
param hash.

### self.dump_all

```ruby
dump_all(messages)
```

[`Brute`](/brute/reference/brute/) log -> the <code>messages:</code> array.
Drops :system messages (see .system_text) and folds consecutive :tool results
into one user turn.

### self.system_text

```ruby
system_text(messages)
```

The :system messages' text, for the top-level <code>system_:</code> parameter.

### self.tool_result_block

```ruby
tool_result_block(message)
```

*Not documented.*

## Defined in

- `lib/brute/message_transport/anthropic.rb`
