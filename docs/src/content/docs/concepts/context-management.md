---
title: Context Management
description: Two guards keep the context window alive — universal truncation of
  tool output, and lossy compaction of the conversation.
sidebar:
  order: 7
---

A long agent run produces tool output by the megabyte and a conversation that outgrows any model's window. Brute guards against this at two levels: *truncation* caps each individual result before it enters the log, and *compaction* shrinks the conversation itself once it fills too much of the window.

## Level one — truncation

Every tool result passes through `Brute::Truncation.truncate` as it is appended to the log. This is the primary guard: even a tool with no internal limits cannot blow up the context.

- **Dual cap** — truncate past 2000 lines or 50 KB, whichever hits first; single lines are capped at 2000 characters.
- **Head or tail** — most output keeps its beginning (head mode); shell results keep their end, where errors and summaries live.
- **Overflow to disk** — when truncating, the full text is saved under `~/.local/share/brute/tool-output/` and the preview carries a hint naming the file, so the model can `read` specific sections back on demand.

Tools that truncated internally (the built-in `read` and `shell`) are not double-truncated.

Truncation is per-result and lossless-by-retrieval: nothing leaves the system, the window just stops carrying all of it at once.

## Level two — compaction

Truncation bounds what one tool costs; compaction bounds the whole conversation. `DefaultCompactionPipeline` decides *when* (once messages fill too much of the model's window); a compactor decides *what goes*.

The default compactor is itself a middleware stack — `Brute::Turn::CompactionPipeline` — and the stack order is the policy:

```ruby
Brute::Turn::CompactionPipeline.new do
  use Brute::Compaction::Middleware::ToolResults    # rewrite older tool output
  use Brute::Compaction::Middleware::SlidingWindow  # drop the oldest turns
  run Brute::Compaction::Summarize.new(chat_generator)
end
```

A layer that got the conversation under target never descends to the next, which keeps free strategies above the one that spends a model call. The pipeline sits inside `Loop::ToolResult`, so it runs before *every* call — a long run of tool results can fill the window without the turn ever ending.

See [Sessions](../sessions/#context-growth) for wiring it into an agent.

## Compaction is lossy, on purpose

Unlike truncation, compaction throws history away permanently and keeps no record of what it gave up. It says so instead — the pipeline emits a `:compacted` event an application can archive from:

```ruby
agent.on(:compacted) { |env, payload| archive(env, payload) }
```

That split — reversible overflow for tool output, irreversible summarisation for conversation — is the design: cheap mechanisms handle what they can, and the expensive, destructive one runs last and only when needed.
