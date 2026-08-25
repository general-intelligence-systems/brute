---
title: "Brute::Events::PrefixedTerminalOutput"
description: "TerminalOutput variant that prefixes all output with a label."
---


```ruby
module Brute::Events
  class PrefixedTerminalOutput < Handler
  end
end
```

[`TerminalOutput`](/brute/reference/brute/events/terminal-output/) variant
that prefixes all output with a label. Useful for sub-agents running
concurrently — the prefix makes it clear which agent produced each line.

Usage in a middleware stack:


```ruby
use Brute::Middleware::EventHandler,
    handler_class: Brute::Events::PrefixedTerminalOutput,
    prefix: "explore"
```

## Class Methods

### self.new

```ruby
new(inner, prefix: "sub-agent")
```

*Not documented.*

## Instance Methods

### #<<

```ruby
<<(event)
```

*Not documented.*

## Defined in

- `lib/brute/events/prefixed_terminal_output.rb`
