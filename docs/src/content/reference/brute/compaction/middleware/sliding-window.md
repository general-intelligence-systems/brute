---
title: "Brute::Compaction::Middleware::SlidingWindow"
description: "When rewriting the tool output was not enough, whole stretches of the conversation go."
---


```ruby
module Brute::Compaction::Middleware
  class SlidingWindow < Strategy
  end
end
```

When rewriting the tool output was not enough, whole stretches of the
conversation go.

The instructions and the message the current task hangs off are never given
up. Past that, the oldest complete turns go first; only once every turn is
gone does the current task start losing its own oldest steps, and never the
newest.

A note stands where the removed messages were, so the model can see that
something was there rather than quietly reasoning from a gap.

## Constants

### NOTE

```ruby
NOTE = "%d earlier messages were dropped to free context. They cannot be recovered."
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(app = nil, keep_steps: 1)
```

*Not documented.*

## Instance Methods

### #rewrite

```ruby
rewrite(messages, target:)
```

*Not documented.*

### #strategy

```ruby
strategy()
```

*Not documented.*

## Defined in

- `lib/brute/compaction/middleware/sliding_window.rb`
