---
title: "Brute::Eval::Case"
description: "One evaluation case: what the agent is told, the world it is told it in, and what must be true of the turn afterwards."
---


```ruby
module Brute::Eval
  class Case
  end
end
```

One evaluation case: what the agent is told, the world it is told it in, and
what must be true of the turn afterwards.


```ruby
Brute::Eval::Case.new(
  "searches for what it cannot know",
  said:     "what did the Bank of England do yesterday?",
  stubs:    { "search" => RATE_DECISION },
  calls:    { "search" => { "query" => /bank|rate/i } },
  mentions: %w[4.25],
  budget:   Brute::Eval::Budget.new(tool_calls: 2),
)
```

The expectations are deliberately about what the turn DID, not about prose: a
call that was made, a call that was not, the order two calls came in, a word
the answer has to contain, a budget it has to stay inside. What none of those
can say goes in the block, which is handed the transcript.

`said` reaches the agent through the world -- an inbox on disk, a queue,
whatever that deployment's world does with it -- unless `via: :start` hands it
straight to the turn. `files` and `conversation` are the world's to lay out
and mean nothing to a world that keeps no state.

## Constants

### ABSENCE

```ruby
ABSENCE = /\b(no|not|none|nothing|cannot|can't|couldn't|didn't|don't|doesn't|isn't|aren't|unable|unfortunately|missing|without)\b/i
```

A system prompt that tells an agent to say plainly when it found nothing is
graded on this. It is a crude reading -- a judge would do it properly -- and
it is English, so a deployment whose agents answer in another language passes
its own <code>absence:</code>.

### Verdict

```ruby
Verdict = Data.define(:failures) do
        def passed? = failures.empty?
      end
```

*Not documented.*

## Attributes

### budget

`budget` &mdash; read-only

*Not documented.*

### conversation

`conversation` &mdash; read-only

*Not documented.*

### files

`files` &mdash; read-only

*Not documented.*

### name

`name` &mdash; read-only

*Not documented.*

### runs

`runs` &mdash; read-only

*Not documented.*

### said

`said` &mdash; read-only

*Not documented.*

### stubs

`stubs` &mdash; read-only

*Not documented.*

### via

`via` &mdash; read-only

*Not documented.*

## Class Methods

### self.new

```ruby
new(name, said: nil, via: :world, files: {}, conversation: [], stubs: {}, calls: {}, never: [], order: [], mentions: [], absent: false, absence: ABSENCE, silent: false, budget: Budget.new, runs: 1, &check)
```

*Not documented.*

## Instance Methods

### #verdict

```ruby
verdict(transcript)
```

*Not documented.*

## Defined in

- `lib/brute/eval/case.rb`
