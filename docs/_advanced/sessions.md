---
layout: default
title: Sessions
nav_order: 2
description: 'The session is just a JSONL log of the conversation on disk, owned by the SessionLog middleware.'
---

# Sessions

Brute has no `Session` class. The "session" is just a JSONL file — one message per line — and the `SessionLog` middleware owns it:

```ruby
Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  # ... rest of the stack ...
```

- **On the way in:** if the file exists, its messages are prepended to `env[:messages]`, so this turn continues the prior conversation.
- **On the way out:** the whole log is written back, one `Brute::Message#to_h` per line as JSON — skipping the `:system` message (the `SystemPrompt` middleware re-adds it each turn).

Put `SessionLog` outermost so history loads before the rest of the stack runs and the complete turn is persisted after.

## The format

Each line is a message's [`to_h`]({% link _core_features/messages.md %}), and loading is the exact inverse:

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

For long conversations, the `CompactionCheck` middleware is the hook point for summarizing older messages once the log crosses a token or message threshold — keeping the context window manageable without losing the thread. It sits inside `SessionLog` so compaction happens against the loaded history.
