---
title: Evaluate an Agent
description: Grade whole assembled agents on what their turns DID — with stubbed
  tools, budgets, and exit-status suites.
sidebar:
  order: 7
---

A unit spec asks whether one middleware does what it says. An eval asks whether the *whole agent* — system prompt, tools, and the model behind it — behaves. `Brute::Eval` runs real turns against a real model and grades what the turn did: which tools were called, in what order, what the answer contained, and what it cost.

## A first suite

```ruby
require "brute/eval"

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

`Suite#run` answers a process exit status — `0` when every case passed, `1` otherwise — so an eval script is a CI step.

## What a case can expect

Expectations are deliberately about what the turn *did*, not its prose:

| Argument | Passes when |
|---|---|
| `said:` | the prompt handed to the agent |
| `calls:` | each named tool was called (arguments matched as regex/hash subset) |
| `never:` | none of these tools were called |
| `order:` | the listed tools were called in exactly this order |
| `mentions:` | every word appears in the final reply |
| `silent: true` | the turn answered nothing (nothing to report) |
| `absent: true` | the reply signals absence ("no results", ...) |
| `budget:` | stayed inside `Budget.new(iterations:, tool_calls:, tokens:, seconds:)` |
| `stubs:` | canned results served instead of real tool execution |
| `files:`, `conversation:` | world state laid out before the turn |
| `runs:` | repeat N times; passes only if **every** run does — models aren't deterministic |

Anything else goes in a block, handed the transcript:

```ruby
Brute::Eval::Case.new("patches the test") do |transcript|
  transcript.failures << "edited the wrong file" unless ...
end
```

## How it observes without changing the agent

The harness subscribes to the agent's own hook registry (`agent.on(...)`) — the same one any other subscriber uses. No eval-only middleware, no branch in your agent file. Tool stubs are installed on `:before_tool`: a call whose name has a canned result is answered without the tool ever running, so the web, calendar, or shell is replaced without building the agent differently.

The agent under test is built fresh for every attempt — from a `.ru` file path, or from a block that returns a new pipeline — so nothing carries between cases.

## Custom worlds

Where a case wakes up is the World's business. The default `Brute::Eval::World` keeps no state: `said` goes straight to the turn. Subclass it for deployments that deliver input some other way — an inbox on disk, a queue, a chat room:

```ruby
class Room < Brute::Eval::World
  def prepare(kase)
    super.tap { |input| inbox.append(kase.said) if input.nil? }
  end
end

Brute::Eval::Suite.new(agent: "agent.ru", world: Room.new, cases: CASES).run
```

A world answers three things: `#prepare(case)` lays out state and returns what the turn starts with (or nil if delivery happened another way), `#stub(agent, stubs)` installs canned tool results, and `#published` records whatever the turn sent outward.
