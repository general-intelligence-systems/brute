---
name: compact
description: Check context usage and compact the conversation from IRuby. Use when context is filling up and substantial work remains, so the session is summarized and you keep working instead of stopping early.
---

# Compact

Compaction replaces older conversation history with a dense summary, freeing
context so long-running work can continue. The implementation lives in the
host (Middleware::Compaction); this skill is the kernel-side interface to it,
preloaded into the kernel namespace. Call it directly from IRuby:

```ruby
compact.status
compact.run
compact.run("keep the failing test names and the migration checklist")
```

## API

- `compact.status` — current context usage as a Hash: `tokens`,
  `context_window`, and `percent` (`nil` right after a compaction until the
  next model response), plus `scheduled` (whether a requested compaction is
  already pending).
- `compact.run(instructions = nil)` — schedule compaction. Returns
  `{"scheduled" => true}`. Optional `instructions` focus the summary on what
  matters for the remaining work.

## Rules

- Compaction never runs mid-cell. A scheduled compaction runs when the
  current turn ends and the harness resumes you automatically afterwards.
  Continue working normally after calling it.
- Kernel state survives compaction: variables, methods, and loaded data
  remain available.
- Compaction is not a completion signal — pending goals, continuations, and
  heartbeats keep running.
