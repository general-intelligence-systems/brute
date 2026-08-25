---
title: "Brute::Eval::Suite"
description: "Runs the cases against one agent and reports what happened."
---


```ruby
module Brute::Eval
  class Suite
  end
end
```

Runs the cases against one agent and reports what happened.


```ruby
Brute::Eval::Suite.new(agent: "agent.ru", cases: CASES).run
Brute::Eval::Suite.new(agent: -> { build_agent }, world: Room.new, cases: CASES).run
```

The agent is built fresh for every attempt -- from its .ru file, or from a
block that answers a new pipeline -- so nothing carries from one case to the
next but the world, which is laid out again first. A case with
<code>runs:</code> above one is run that many times and passes only if every
run did: the model is not deterministic, and a case that passes two times in
three is a case that fails.

[`#run`](/brute/reference/brute/eval/suite/#run) answers a process exit
status, so an eval script ends `exit(...)`.

## Constants

### Result

```ruby
Result = Data.define(:kase, :run, :transcript, :verdict)
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(agent:, cases:, world: World.new, out: $stdout)
```

*Not documented.*

## Instance Methods

### #run

```ruby
run()
```

*Not documented.*

## Defined in

- `lib/brute/eval/suite.rb`
