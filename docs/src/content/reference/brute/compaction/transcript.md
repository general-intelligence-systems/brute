---
title: "Brute::Compaction::Transcript"
description: "The shapes a compaction strategy selects over."
---


```ruby
module Brute::Compaction
  module Transcript
  end
end
```

The shapes a compaction strategy selects over.

A transcript is an Array of
[`Brute::Message`](/brute/reference/brute/#message), but what may be given up
is never a single message. An assistant's tool calls travel with the results
that answer them, and a user's question with everything said before the next
one -- a provider rejects the halves. So a strategy works in groups: a
**step** is an assistant message and the tool results immediately after it, a
**turn** is a real user message and everything up to the next.

A message a strategy produced carries its name at the head of its content,
because [`Brute::Message`](/brute/reference/brute/#message) has nowhere else
to put it. That is what stops a later pass from summarising a summary.

## Constants

### MARK

```ruby
MARK = /\A\[compacted:([a-z_]+)\]/
```

*Not documented.*

## Class Methods

### self.at

```ruby
at(messages, indices)
```

*Not documented.*

### self.line

```ruby
line(message)
```

*Not documented.*

### self.mark

```ruby
mark(strategy, text)
```

*Not documented.*

### self.marked?

```ruby
marked?(message, strategy = nil)
```

*Not documented.*

### self.render

```ruby
render(messages)
```

The transcript as plain text, for a summariser to read. Rendering it rather
than replaying the messages keeps a half tool exchange -- a call whose result
was left behind, a result whose call was -- off the wire, which is a shape
providers refuse.

It is the same text the counters measure, so what a summariser is asked to
shrink and what the trigger weighed are one thing.

### self.step_start

```ruby
step_start(messages)
```

Where the current task's steps begin: after its anchor, or after the
instructions when the conversation has no anchor at all.

### self.steps

```ruby
steps(messages, from:)
```

An assistant message and every tool result answering it, as index ranges.

### self.system_end

```ruby
system_end(messages)
```

Where the leading system block ends. Nothing above this is ever given up.

### self.task_index

```ruby
task_index(messages)
```

The user message the current task hangs off, ignoring whatever an earlier
compaction left behind.

### self.tokens

```ruby
tokens(messages)
```

Roughly what a slice costs, for code holding messages rather than an env. A
strategy weighs with the turn's own counter instead -- see
[`Brute::Compaction.counter`](/brute/reference/brute/compaction/#selfcounter).

### self.turns

```ruby
turns(messages, from:, to:)
```

A real user message and everything up to the next one, as index ranges.

## Defined in

- `lib/brute/compaction/transcript.rb`
