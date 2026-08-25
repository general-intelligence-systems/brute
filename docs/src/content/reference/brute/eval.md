---
title: "Brute::Eval"
description: "Evaluating an agent, rather than testing a middleware."
---


```ruby
module Brute
  module Eval
  end
end
```

Evaluating an agent, rather than testing a middleware.

A spec asks whether one layer does what it says. An eval asks whether the
whole assembled agent -- its system prompt, its tools, the model behind it --
behaves. That answer is not a boolean about code: it is a real turn, against a
real model, graded on what the turn DID.


```ruby
CASES = [
  Brute::Eval::Case.new(
    "searches for what it cannot know",
    said:     "what did the Bank of England do yesterday?",
    stubs:    { "search" => RATE_DECISION },
    calls:    { "search" => { "query" => /bank|rate/i } },
    mentions: %w[4.25],
  ),
  Brute::Eval::Case.new(
    "does not search for what it already knows",
    said:   "how many minutes are there in an hour?",
    never:  %w[search],
    budget: Brute::Eval::Budget.new(iterations: 2, tool_calls: 0),
  ),
]

exit(Brute::Eval::Suite.new(agent: "agent.ru", cases: CASES).run)
```

Everything the harness sees comes off the agent's own hooks -- the same
registry any other subscriber uses -- so the agent under evaluation is the
agent that ships: no eval-only middleware, no branch in agent.ru. The model
and the tool schemas are real; the tools themselves answer from the case's
stubs, installed on :before_tool, which answers a call without executing it.

Where a case wakes up is the World's business, and a deployment that delivers
what was said through an inbox, a queue or a room subclasses it.

## Constants

### Budget

```ruby
Budget = Data.define(:iterations, :tool_calls, :tokens, :seconds) do
      def initialize(iterations: 10, tool_calls: 8, tokens: 100_000, seconds: 180)
        super
      end
    end
```

The budget a case allows itself. Lenient on purpose: an agent that took one
search too many is worth knowing about, but it is not the same fault as an
agent that answered wrongly.

## Defined in

- `lib/brute/eval.rb`
- `lib/brute/eval/case.rb`
- `lib/brute/eval/suite.rb`
- `lib/brute/eval/transcript.rb`
- `lib/brute/eval/world.rb`
