---
title: "Brute::MessageTransport::OpenRouter"
description: "MessageTransport for the open_router_enhanced gem (https://github.com/estiens/open_router_enhanced)."
---


```ruby
module Brute::MessageTransport
  class OpenRouter < Brute::MessageTransport
  end
end
```

[`MessageTransport`](/brute/reference/brute/message-transport/) for the
open_router_enhanced gem (https://github.com/estiens/open_router_enhanced).
[`Brute`](/brute/reference/brute/) does not require it — you do:


```ruby
require "open_router"
```

## Class Methods

### self.dump

```ruby
dump(message)
```

*Not documented.*

### self.usage_metrics

```ruby
usage_metrics(response)
```

What the provider reported about this call — the transport knows its own
library's shape, so it knows which detector to ask.

## Instance Methods

### #messages

```ruby
messages()
```

An OpenRouter::Response's messages (one per choice; in practice
[`OpenRouter`](/brute/reference/brute/message-transport/open-router/) returns
exactly one).

## Defined in

- `lib/brute/message_transport/open_router.rb`
