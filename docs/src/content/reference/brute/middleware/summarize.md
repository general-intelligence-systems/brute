---
title: "Brute::Middleware::Summarize"
description: "Runs a final tool-free LLM call after the Loop::ToolResult completes, ensuring the agent produces a clean summary response."
---


```ruby
module Brute::Middleware
  class Summarize < Base
  end
end
```

Runs a final tool-free LLM call after the
[`Loop::ToolResult`](/brute/reference/brute/middleware/loop/tool-result/)
completes, ensuring the agent produces a clean summary response.

This middleware sits above
[`Loop::ToolResult`](/brute/reference/brute/middleware/loop/tool-result/) in
the stack. After the tool loop finishes (either naturally or via
[`MaxIterations`](/brute/reference/brute/middleware/max-iterations/)),
[`Summarize`](/brute/reference/brute/middleware/summarize/) injects a summary
prompt and calls the inner stack one more time with tools removed. The LLM
responds with text only, giving the agent a proper final answer.

Stack order:


```
use Summarize
use Loop::ToolResult
use MaxIterations
use ToolPipeline
run ->(env) { ... }   # inline LLM call proc (see Brute.agent)
```

## Constants

### DEFAULT_PROMPT

```ruby
DEFAULT_PROMPT = "Provide your complete findings based on everything you've explored."
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(app, prompt: DEFAULT_PROMPT)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/004_summarize.rb`
