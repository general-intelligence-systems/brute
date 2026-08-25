---
title: "Brute::Middleware::Checkpoint"
description: "Durable execution for the tool loop."
---


```ruby
module Brute::Middleware
  class Checkpoint < Base
  end
end
```

Durable execution for the tool loop. Where
[`SessionLog`](/brute/reference/brute/middleware/session-log/) persists the
conversation once per turn (outermost),
[`Checkpoint`](/brute/reference/brute/middleware/checkpoint/) snapshots it
after every pass through the inner stack — one checkpoint per LLM call + tool
execution. Place it just inside
[`Loop::ToolResult`](/brute/reference/brute/middleware/loop/tool-result/):


```ruby
use Brute::Middleware::Loop::ToolResult
use Brute::Middleware::Checkpoint, path: "tmp/checkpoints.jsonl"
use Brute::Middleware::MaxIterations
use Brute::Middleware::DefaultToolPipeline, tools: Brute::Tools::ALL
```

The store is just a JSONL log of snapshots — one line per checkpoint, each
carrying the full message log plus its own id and the id of the parent
checkpoint it grew from. That append-only chain buys three things:


```
resume       pass resume: :latest — a crash mid-turn costs at most
             one iteration instead of the whole turn
time travel  pass resume: "<checkpoint id>" — restart from any
             snapshot in the chain
forking      checkpoints written after a time-travel resume carry the
             resumed id as parent_id, branching the chain in place
```

System messages are not persisted
([`SystemPrompt`](/brute/reference/brute/middleware/system-prompt/) re-adds
them each turn); restored history is inserted after any leading system message
and before the current turn's input.

## Class Methods

### self.list

```ruby
list(path)
```

Parsed checkpoint records (symbol keys, messages as plain hashes), oldest
first.

### self.new

```ruby
new(app, path:, resume: nil)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/008_checkpoint.rb`
