---
title: "Brute::Middleware::Loop::ToolResult"
description: "Loops while the LLM keeps producing tool results — the standard agentic turn loop."
---


```ruby
module Brute::Middleware::Loop
  class ToolResult < Brute::Middleware::Loop
  end
end
```

Loops while the LLM keeps producing tool results — the standard agentic turn
loop. After the inner stack runs (the LLM-call proc responds,
[`ToolPipeline`](/brute/reference/brute/middleware/tool-pipeline/) executes
tools and appends :tool messages), it loops when the last message is a tool
result, bumping the iteration counter. It stops when the LLM answers with text
only or `env[:should_exit]` is set (e.g. by
[`MaxIterations`](/brute/reference/brute/middleware/max-iterations/)).


```ruby
use Brute::Middleware::Loop::ToolResult
```

## Constants

### CONDITION

```ruby
CONDITION = lambda do |env|
          if env[:should_exit]
            next false
          end

          unless env[:messages].last&.role == :tool
            next false
          end

          env[:current_iteration] += 1

          true
        end
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(app)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/006_loop.rb`
