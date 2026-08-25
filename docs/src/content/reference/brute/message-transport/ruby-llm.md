---
title: "Brute::MessageTransport::RubyLLM"
description: "Class Brute::MessageTransport::RubyLLM."
---


```ruby
module Brute::MessageTransport
  class RubyLLM < Brute::MessageTransport
  end
end
```

## Class Methods

### self.dump

```ruby
dump(message)
```

[`Brute::Message`](/brute/reference/brute/#message) -> RubyLLM::Message (tool
calls as ruby_llm's id-keyed hash).

### self.usage_metrics

```ruby
usage_metrics(message)
```

What the provider reported about this call — the transport knows its own
library's shape, so it knows which detector to ask.

## Defined in

- `lib/brute/message_transport/ruby_llm.rb`
