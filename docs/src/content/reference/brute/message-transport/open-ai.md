---
title: "Brute::MessageTransport::OpenAI"
description: "MessageTransport for the official openai gem (https://github.com/openai/openai-ruby)."
---


```ruby
module Brute::MessageTransport
  class OpenAI < Brute::MessageTransport
  end
end
```

[`MessageTransport`](/brute/reference/brute/message-transport/) for the
official openai gem (https://github.com/openai/openai-ruby).
[`Brute`](/brute/reference/brute/) does not require it —you do:


```
require "openai"

client = OpenAI::Client.new(api_key: ENV["OPENAI_API_KEY"])
response = client.chat.completions.create(
  model:    "gpt-5",
  messages: Brute::MessageTransport::OpenAI.dump_all(env[:messages]),
  tools:    ...,
)
Brute::MessageTransport::OpenAI.wrap_each(response) { |m| env[:messages] << m }
```

## Class Methods

### self.dump

```ruby
dump(message)
```

[`Brute::Message`](/brute/reference/brute/#message) -> a chat.completions
message param hash.

## Instance Methods

### #messages

```ruby
messages()
```

A chat completion response's messages (one per choice).

## Defined in

- `lib/brute/message_transport/openai.rb`
