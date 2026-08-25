---
title: "Brute::MessageTransport::LangChain"
description: "MessageTransport for the langchainrb gem."
---


```ruby
module Brute::MessageTransport
  class LangChain < RubyOpenAI
  end
end
```

[`MessageTransport`](/brute/reference/brute/message-transport/) for the
langchainrb gem. Its [`LLM`](/brute/reference/brute/message-transport/llm/)
classes speak the OpenAI-style wire format, so the message conversion is
RubyOpenAI's —what differs is usage, which langchainrb answers through
per-provider response methods rather than a usage object.

## Class Methods

### self.usage_metrics

```ruby
usage_metrics(response)
```

*Not documented.*

## Defined in

- `lib/brute/message_transport/lang_chain.rb`
