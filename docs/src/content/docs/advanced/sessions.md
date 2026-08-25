---
title: Sessions
description: The session is just a JSONL log of the conversation on disk, owned by
  the SessionLog middleware.
sidebar:
  order: 2
---

Brute has no `Session` class. The "session" is just a JSONL file — one message per line — and the `SessionLog` middleware owns it:

```ruby
Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::DefaultCompactionPipeline,
       window: 200_000,
       compactor: Brute::Turn::CompactionPipeline.new do
         use Brute::Compaction::Middleware::ToolResults    # rewrite older tool output
         use Brute::Compaction::Middleware::SlidingWindow  # drop the oldest turns
         run Brute::Compaction::Summarize.new(chat_generator)
       end)
  .use(Brute::Middleware::DefaultToolPipeline, tools: Brute::Tools::ALL)
```

`DefaultCompactionPipeline` is that same ladder already wired, for agents that
want ordinary compaction without saying all of it:

```ruby
.use(Brute::Middleware::DefaultCompactionPipeline, window: 200_000, summariser: chat_generator)
```

- **On the way in:** if the file exists, its messages are prepended to `env[:messages]`, so this turn continues the prior conversation.
- **On the way out:** the whole log is written back, one `Brute::Message#to_h` per line as JSON — skipping the `:system` message (the `SystemPrompt` middleware re-adds it each turn).

Put `SessionLog` outermost so history loads before the rest of the stack runs and the complete turn is persisted after.

## The format

Each line is a message's [`to_h`](../messages/), and loading is the exact inverse:

```ruby
Brute::Message.new(**JSON.parse(line, symbolize_names: true))
```

Because `Brute::Message` symbolizes roles and coerces `tool_calls` hashes into `ToolCall`, the round-trip is lossless — a persisted tool-calling turn reloads with its structure intact. A sample line:

```json
{"role":"assistant","content":"","tool_calls":[{"id":"tc1","name":"shell","arguments":{"command":"ls"}}]}
```

## Multi-turn

Run the same agent twice against the same path and the second turn sees the first:

```ruby
agent = Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/chat.jsonl")
  .use(Brute::Middleware::SystemPrompt)
  .run ->(env) { ... }

agent.start("My name is Nathan.")
agent.start("What's my name?")   # history is loaded; the model has the context
```

Use a different path per conversation to keep them separate; delete the file to start fresh.

## Context growth

For long conversations, `DefaultCompactionPipeline` gives up part of the history once
it fills too much of the model's window. It decides *when*; a compactor decides
*what goes*.

`Brute::Turn::CompactionPipeline` builds that compactor out of middleware, so
the stack order is the policy: a layer that got the conversation under target
never calls the next, which keeps the strategies that cost nothing above the
one that spends a model call.

```ruby
Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::DefaultCompactionPipeline,
       window: 200_000,
       compactors: [
         Brute::Compaction::ToolResults.new,     # rewrite older tool output
         Brute::Compaction::SlidingWindow.new,   # drop the oldest turns
         Brute::Compaction::Summary.new(summarize: summarize),
       ])
  .use(Brute::Middleware::DefaultToolPipeline, tools: Brute::Tools::ALL)
```

It belongs inside `Loop::ToolResult` rather than around it, so it runs before
every call — a long run of tool results can fill the window without the turn
ever ending. It sits inside `SessionLog` too, so it works against the loaded
history and `SessionLog` persists what survives.

Compaction is lossy and the pipeline keeps no record of what it gave up. It
says so instead, and an application that wants the original preserves it:

```ruby
agent.on(:compacted) { |env, payload| archive(env, payload) }
```
