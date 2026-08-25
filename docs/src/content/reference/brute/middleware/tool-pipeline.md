---
title: "Brute::Middleware::ToolPipeline"
description: "The old name for DefaultToolPipeline, kept working while it is deprecated."
---


```ruby
module Brute::Middleware
  class ToolPipeline < DefaultToolPipeline
    extend GemKit::Deprecate
  end
end
```

The old name for
[`DefaultToolPipeline`](/brute/reference/brute/middleware/default-tool-pipelin
e/), kept working while it is deprecated. The middleware is one particular
wiring of tool dispatch and the name now says so, leaving
[`Brute::Turn::ToolPipeline`](/brute/reference/brute/turn/tool-pipeline/) as
the mechanism to compose when that wiring is not what you want.


```ruby
use Brute::Middleware::DefaultToolPipeline, tools: tools
```

## Defined in

- `lib/brute/middleware/070_tool_pipeline.rb`
