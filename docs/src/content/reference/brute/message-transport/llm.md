---
title: "Brute::MessageTransport::LLM"
description: "MessageTransport for the llm.rb gem (https://github.com/llmrb/llm.rb)."
---


```ruby
module Brute::MessageTransport
  class LLM < Brute::MessageTransport
  end
end
```

[`MessageTransport`](/brute/reference/brute/message-transport/) for the llm.rb
gem (https://github.com/llmrb/llm.rb). [`Brute`](/brute/reference/brute/) does
not require llm.rb — you do:


```
require "llm"

llm = LLM.openai(key: ENV["OPENAI_API_KEY"])
messages = Brute::MessageTransport::LLM.dump_all(env[:messages])
response = llm.complete(messages.pop, role: nil, messages: messages, tools: ...)
Brute::MessageTransport::LLM.wrap_each(response) { |m| env[:messages] << m }
```

## Class Methods

### self.dump

```ruby
dump(message)
```

[`Brute::Message`](/brute/reference/brute/#message) -> LLM::Message. Assistant
tool calls carry llm.rb's `original_tool_calls` extra (the provider wire
format); tool results become an LLM::Function::Return so llm.rb's request
adapters emit them correctly.

### self.usage_metrics

```ruby
usage_metrics(response)
```

What the provider reported about this call — the transport knows its own
library's shape, so it knows which detector to ask.

## Defined in

- `lib/brute/message_transport/llm.rb`
