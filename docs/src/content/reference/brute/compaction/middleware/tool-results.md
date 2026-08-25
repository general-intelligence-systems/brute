---
title: "Brute::Compaction::Middleware::ToolResults"
description: "The cheapest thing to give up first: what the tools said."
---


```ruby
module Brute::Compaction::Middleware
  class ToolResults < Strategy
  end
end
```

The cheapest thing to give up first: what the tools said.

[`Tool`](/brute/reference/brute/tool/) output dominates a long run, and most
of it stops being useful the moment the model has acted on it. So the results
are rewritten in place rather than removed -- every call keeps the result that
answers it, the model can still see what it ran, and it can run it again if it
turns out it still needed the answer.

Oldest first, and it stops the moment the transcript is under target, so the
most recent output survives the longest.

## Constants

### PLACEHOLDER

```ruby
PLACEHOLDER = "Result dropped to free context. Call %s again if you still need it."
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(app = nil, keep_steps: 1, min_tokens: 200)
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

- `lib/brute/compaction/middleware/tool_results.rb`
