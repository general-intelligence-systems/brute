---
title: "Brute::Compaction::Middleware::Strategy"
description: "One strategy in the ladder."
---


```ruby
module Brute::Compaction::Middleware
  class Strategy < Brute::Middleware::Base
  end
end
```

One strategy in the ladder.

The stack order is the policy. A layer that got the conversation under target
never calls the next one, so the strategies that cost nothing sit at the top
and the one that spends a model call is only reached when they could not get
there.

A subclass answers
[`#strategy`](/brute/reference/brute/compaction/middleware/strategy/#strategy)
and
[`#rewrite`](/brute/reference/brute/compaction/middleware/strategy/#rewrite),
and nothing else. The rules every strategy has to keep are here: it is only
asked while the conversation is over target, and what it answers is only taken
when it actually made the conversation smaller -- otherwise the pipeline above
would write the same size back on every step, forever.

The same class serves as a layer or as the terminal, which is what the ladder
is built out of: the strategies that cost nothing are `use`d, and the one that
spends a model call is `run`, reached only when they could not get under
target.


```ruby
Brute::Turn::CompactionPipeline.new do
  use Brute::Compaction::Middleware::ToolResults
  use Brute::Compaction::Middleware::SlidingWindow
  run Brute::Compaction::Middleware::Summary.new(summarize: summarize)
end
```

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

### #rewrite

```ruby
rewrite(_conversation, target:)
```

Answer a smaller conversation, or nil to decline. Build a new list: the one
handed over belongs to the caller.

### #strategy

```ruby
strategy()
```

The name this strategy compacts under, recorded on what it produces.

## Defined in

- `lib/brute/compaction/middleware/strategy.rb`
