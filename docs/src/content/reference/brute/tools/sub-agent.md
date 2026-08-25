---
title: "Brute::Tools::SubAgent"
description: "A SubAgent is an Agent that exposes a tool-shaped facade so it can be dropped into another agent's tools list."
---


```ruby
module Brute::Tools
  class SubAgent < Brute::Turn::AgentPipeline
  end
end
```

A [`SubAgent`](/brute/reference/brute/tools/sub-agent/) is an Agent that
exposes a tool-shaped facade so it can be dropped into another agent's tools
list. The parent agent hands it to the LLM as a regular tool; when invoked,
the [`SubAgent`](/brute/reference/brute/tools/sub-agent/) runs its own
pipeline against a fresh Session built from the tool arguments, then returns
the final assistant message as the tool result.

Usage:


```
researcher = Brute::Tools::SubAgent.new(
  name:        "research",
  description: "Delegate a research task to a read-only sub-agent.",
) do
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::Loop::ToolResult
  use Brute::Middleware::MaxIterations, max_iterations: 10
  use Brute::Middleware::DefaultToolPipeline, tools: [Brute::Tools::FSRead, Brute::Tools::FSSearch]
  run ->(env) do
    # The LLM call, written with your library of choice. Convert
    # env[:messages] to its format, call it, and append the response
    # back as Brute::Message values (the MessageTransport pattern —
    # see examples/ruby_llm.rb, examples/openai.rb, ...).
  end
end

# The SubAgent IS a tool — hand it to a parent agent's ToolPipeline:
main_agent = Brute.agent do
  use Brute::Middleware::DefaultToolPipeline, tools: [Brute::Tools::FSRead, researcher]
  run ->(env) { ... }
end
main_agent.start("delegate some research")
```

## Constants

### DEFAULT_PARAMS

```ruby
DEFAULT_PARAMS = {
        task: { type: "string", desc: "A clear, detailed description of the task", required: true },
      }.freeze
```

*Not documented.*

## Attributes

### description

`description` &mdash; read-only

*Not documented.*

### params

`params` &mdash; read-only

*Not documented.*

### sub_agent_name

`sub_agent_name` &mdash; read-only

*Not documented.*

## Class Methods

### self.new

```ruby
new(name:, description:, params: DEFAULT_PARAMS, &block)
```

*Not documented.*

## Instance Methods

### #execute

```ruby
execute(arguments)
```

Tool-shaped entry point. Builds a session from arguments, runs the agent loop,
returns the last assistant message as a string.

### #name

```ruby
name()
```

Lets ToolPipeline treat SubAgents the same as any other tool without checking
respond_to? everywhere.

## Defined in

- `lib/brute/tools/sub_agent.rb`
