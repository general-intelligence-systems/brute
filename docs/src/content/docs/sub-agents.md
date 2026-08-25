---
title: Sub-Agents
description: A SubAgent is a full agent wearing a tool-shaped facade, so delegation
  and parallel exploration compose like any other tool.
---

A `Brute::Tools::SubAgent` is an `AgentPipeline` that also exposes a tool interface (`name`, `description`, `params`, `execute`). Hand it to a parent agent's `ToolPipeline` and the parent's model can call it like any other tool. When invoked, the sub-agent builds a fresh conversation from the tool arguments, runs its own full middleware pipeline, and returns its final assistant message as the tool result.

This is how delegation and parallel exploration work: a coordinator agent fans work out to focused sub-agents (a read-only explorer, a researcher), each with its own tools, prompt, and iteration budget.

## Defining one

```ruby
researcher = Brute::Tools::SubAgent.new(
  name:        "research",
  description: "Delegate a research task to a read-only sub-agent.",
) do
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::Loop::ToolResult
  use Brute::Middleware::MaxIterations, max_iterations: 10
  use Brute::Middleware::DefaultToolPipeline, tools: [Brute::Tools::FSRead, Brute::Tools::FSSearch]
  run do |env|
    # the sub-agent's own LLM call — same MessageTransport pattern as any agent
  end
end
```

The default parameter is `task` (a string); override `params:` for a richer argument schema.

## Using one

A SubAgent *is* a tool, so it drops straight into a parent's tool list:

```ruby
main = Brute.agent do
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::Loop::ToolResult
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::DefaultToolPipeline, tools: [Brute::Tools::FSRead, researcher]
  run ->(env) { ... }
end

main.start("Research how sessions are persisted, then summarize.")
```

When the parent's model calls `research`, the sub-agent runs `start` on a fresh log seeded with the `task` argument, loops through its own tool cycle, and hands back the last non-empty assistant message. If it produces no text, the result is a placeholder note rather than an error.

## Why it composes

`SubAgent < AgentPipeline < Pipeline`, and the [Adapter](../tools/) recognizes it directly — so a sub-agent is subject to the same concurrent execution, output truncation, and error-capture as every other tool. Nesting agents costs nothing beyond another pipeline; there is no special "delegation" machinery to learn.
