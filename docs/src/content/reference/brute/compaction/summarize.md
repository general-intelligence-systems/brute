---
title: "Brute::Compaction::Summarize"
description: "Replaces stretches of the conversation with summaries of them, round after round, until it fits or there is nothing left it is allowed to give up."
---


```ruby
module Brute::Compaction
  class Summarize
  end
end
```

Replaces stretches of the conversation with summaries of them, round after
round, until it fits or there is nothing left it is allowed to give up.

This is the terminal app because it is the only strategy that always has an
answer and the only one that costs money -- so it sits at the bottom, and the
free layers above it descend only when they have failed.


```ruby
run Brute::Compaction::Summarize.new(
  Brute::Completion::OpenRouter.new(config: { access_token: key }),
)
```

Each round gives up as little as it can. Four tiers are tried in order, so the
oldest and least useful context goes first and the current task goes last;
within a region a stretch is summarized once before any summary is combined,
since summarizing a summary loses more than summarizing a turn did.


```
1. the oldest complete historical turns
2. no turns left, so the oldest historical summaries, combined
3. the oldest steps of the current task, keeping the newest
4. no step may go, so the current task's own summaries, combined
```

It stops at the last round that worked. A generator that answers nothing
usable, a summary that came back no smaller than what it replaced, or a call
that raised all end the loop with the conversation as the previous round left
it -- keeping the raw messages is the better outcome, and going round again
would only pay to learn the same thing.

## Constants

### INSTRUCTION

```ruby
INSTRUCTION = <<~PROMPT
```

*Not documented.*

### STRATEGY

```ruby
STRATEGY = "summary"
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(generator, keep_steps: 1, approximate_summary_tokens: 1_024)
```

prompt off `env[:messages]` and appends its reply there. A
[`Brute`](/brute/reference/brute/) completion is one; so is a lambda that does
the same.

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/compaction/summarize.rb`
