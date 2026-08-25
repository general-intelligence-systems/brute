---
title: "Brute::MessageTransport"
description: "Class Brute::MessageTransport."
---


```ruby
module Brute
  class MessageTransport
  end
end
```

## Class Methods

### self.dump

```ruby
dump(message)
```

Outbound: one [`Brute::Message`](/brute/reference/brute/#message) in the
library's format. Identity here.

### self.dump_all

```ruby
dump_all(messages)
```

Outbound: the whole log in the library's format.

### self.new

```ruby
new(result)
```

*Not documented.*

### self.usage_metrics

```ruby
usage_metrics(_result)
```

Inbound: what the provider reported about this call, as a
[`Brute::UsageDetection::Usage`](/brute/reference/brute/usage-detection/#usage
). Each transport knows its own library's response shape, so it is the one
that knows which detector to ask. Answers nil for a library that reports no
usage at all.

### self.wrap_each

```ruby
wrap_each(result, &block)
```

Convenience:
[`Brute::MessageTransport.wrap_each(result)`](/brute/reference/brute/message-t
ransport/#selfwrap_each) { |m| ... }

## Instance Methods

### #messages

```ruby
messages()
```

The result normalized to a flat list of the library's messages. A single
message, an array, or anything transcript-shaped (responds to
[`#messages`](/brute/reference/brute/message-transport/#messages)).

### #wrap_each

```ruby
wrap_each() { |wrap(message)| ... }
```

*Not documented.*

## Defined in

- `lib/brute/message_transport.rb`
- `lib/brute/message_transport/anthropic.rb`
- `lib/brute/message_transport/lang_chain.rb`
- `lib/brute/message_transport/llm.rb`
- `lib/brute/message_transport/open_router.rb`
- `lib/brute/message_transport/openai.rb`
- `lib/brute/message_transport/ruby_llm.rb`
- `lib/brute/message_transport/ruby_open_ai.rb`
