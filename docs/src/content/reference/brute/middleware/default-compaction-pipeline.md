---
title: "Brute::Middleware::DefaultCompactionPipeline"
description: "Compacts the conversation once it fills too much of the model's window."
---


```ruby
module Brute::Middleware
  class DefaultCompactionPipeline < Base
  end
end
```

Compacts the conversation once it fills too much of the model's window.

This layer owns the **when**: before each call it estimates the size of the
conversation, and once it reaches `compact_at` of the window it asks a
compactor to bring it down to `compact_to`. What is given up, and in what
order, is the compactor's business.


```ruby
use Brute::Middleware::Loop::ToolResult
use Brute::Middleware::DefaultCompactionPipeline,
  window:     200_000,
  summariser: Brute::Completion::OpenRouter.new(config: { access_token: key })
use Brute::Middleware::DefaultToolPipeline, tools: tools
```

The compactor it builds is the usual ladder, cheapest first:


```
use Brute::Compaction::Middleware::ToolResults     rewrite older tool output
use Brute::Compaction::Middleware::SlidingWindow   drop the oldest turns, then steps
run Brute::Compaction::Summarize                   summarise what is left, until it fits
```

Pass <code>compactor:</code> to say something else. A
[`Brute::Turn::CompactionPipeline`](/brute/reference/brute/turn/compaction-pip
eline/) is the usual thing to pass, but anything answering `#compact(messages,
target:)` will do. Passing no summariser leaves the terminal doing nothing,
which is how an agent says it would rather live with a full context than pay
to shrink it.

It belongs inside the tool loop rather than around it, so it runs before every
call rather than once a turn -- a long run of tool results can fill the window
without the turn ever ending.

Sizing anchors on what the provider itself counted for the last call and
measures locally only what has been appended since, so the estimate is exact
for the bulk of the conversation and approximate only for its tail.

[`Tool`](/brute/reference/brute/tool/) schemas ride in every request and are
part of what fills a window, so they are counted too -- against the trigger
when nothing has been reported yet, and off the target the compactor is given,
because what the schemas occupy is not room the conversation may have. This
layer sits above the tool pipeline, so on the very first call of a turn
`env[:tools]` is not set yet: pass <code>tools:</code> to have them counted
then.

[`Compaction`](/brute/reference/brute/compaction/) is lossy, and this layer
keeps no record of what it gave up: it rewrites `env[:messages]` and says so
with :compacted. An application that keeps a transcript preserves it from
there.


```ruby
agent.on(:compacted) { |env, payload| archive(env, payload) }
```

## Class Methods

### self.compactor

```ruby
compactor(summariser: nil, keep_steps: 2)
```

The ladder this layer wires when it is not given one.

### self.new

```ruby
new(app, window:, summariser: nil, compactor: nil, keep_steps: 2, compact_at: 0.7, compact_to: 0.4, token_counter: nil, tools: nil)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/040_default_compaction_pipeline.rb`
