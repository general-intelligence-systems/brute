---
title: "Brute::Compaction"
description: "Giving up part of a conversation so the rest still fits."
---


```ruby
module Brute
  module Compaction
  end
end
```

Giving up part of a conversation so the rest still fits.

The strategies are middleware (Brute::Middleware::Compact) and they are
composed into a compactor by
[`Brute::Turn::CompactionPipeline`](/brute/reference/brute/turn/compaction-pip
eline/). What lives here is what every one of them needs: the grouping in
[`Transcript`](/brute/reference/brute/compaction/transcript/), the counter
that decides how big anything is, and the two questions the stack is built
around.

A compaction env carries the conversation on <code>:conversation</code> rather
than <code>:messages</code>, because <code>:messages</code> is the prompt
channel the terminal app reads and answers on -- the same contract a
completion has in any other [`Brute`](/brute/reference/brute/) pipeline.
---
Compactors that end a
[`Brute::Turn::CompactionPipeline`](/brute/reference/brute/turn/compaction-pip
eline/): the strategy of last resort, reached only when the layers above could
not get the conversation under target on their own.

## Class Methods

### self.counter

```ruby
counter(env)
```

Whatever the turn decided to weigh with, remembered on the env so the trigger
and every strategy below it answer the same question the same way.
[`Brute::TokenCounter::Approximate`](/brute/reference/brute/token-counter/appr
oximate/) when nobody said otherwise.

### self.over_target?

```ruby
over_target?(env)
```

Is the conversation still bigger than it is allowed to be?

### self.tokens

```ruby
tokens(env, messages = env[:conversation])
```

*Not documented.*

## Defined in

- `lib/brute/compaction.rb`
- `lib/brute/compaction/middleware/sliding_window.rb`
- `lib/brute/compaction/middleware/strategy.rb`
- `lib/brute/compaction/middleware/tool_results.rb`
- `lib/brute/compaction/summarize.rb`
- `lib/brute/compaction/transcript.rb`
