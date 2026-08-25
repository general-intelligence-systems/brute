---
title: "Brute::Turn::CompactionPipeline"
description: "A compactor built out of middleware."
---


```ruby
module Brute::Turn
  class CompactionPipeline
  end
end
```

A compactor built out of middleware.

Like [`ToolPipeline`](/brute/reference/brute/turn/tool-pipeline/) it
**composes** a [`Pipeline`](/brute/reference/brute/turn/pipeline/) rather than
inheriting: the definition block is instance_eval'd into the internal
[`Pipeline`](/brute/reference/brute/turn/pipeline/), so `use` / `run` inside
it are the builder's methods.

The stack order is the policy. A layer that got the conversation under target
does not call the next one, so the strategies that cost nothing sit at the top
and the terminal app -- the summariser, the only thing here that spends money
-- is reached only when they could not get there. That is `run` meaning what
it means everywhere else in Brute: the model call, at the bottom, with the
layers deciding what reaches it.


```ruby
Brute::Turn::CompactionPipeline.new do
  use Brute::Compaction::Middleware::ToolResults,   keep_steps: 1
  use Brute::Compaction::Middleware::SlidingWindow, keep_steps: 2

  run Brute::Compaction::Summarize.new(
    Brute::Completion::OpenRouter.new(config: { access_token: key }),
  )
end
```

A pipeline that must never spend a call is the first two layers and `run
->(env) { env }` -- a policy said out loud rather than configured.

The conversation being compacted rides on <code>env[:conversation]</code>,
leaving <code>env[:messages]</code> to mean what it means to every other
terminal app in Brute: the prompt going down, the reply coming back.

It answers
[`#compact`](/brute/reference/brute/turn/compaction-pipeline/#compact), so
what comes out drops into
[`Brute::Middleware::DefaultCompactionPipeline`](/brute/reference/brute/middle
ware/default-compaction-pipeline/) as that turn's compactor.

## Class Methods

### self.new

```ruby
new(&block)
```

*Not documented.*

## Instance Methods

### #compact

```ruby
compact(messages, target:, events: Pipeline::NullSink.new, token_counter: nil)
```

Answer a smaller conversation, or nil when nothing was given up.

## Defined in

- `lib/brute/turn/compaction_pipeline.rb`
