---
title: "Brute::Turn::ToolPipeline"
description: "A ToolPipeline runs a tool call through a middleware stack."
---


```ruby
module Brute::Turn
  class ToolPipeline
  end
end
```

A [`ToolPipeline`](/brute/reference/brute/turn/tool-pipeline/) runs a tool
call through a middleware stack. Like
[`AgentPipeline`](/brute/reference/brute/turn/agent-pipeline/) it **composes**
a [`Pipeline`](/brute/reference/brute/turn/pipeline/) rather than inheriting:
the definition block is instance_eval'd into the internal
[`Pipeline`](/brute/reference/brute/turn/pipeline/), so `use` / `run` inside
it are the builder's methods. The tool's terminal app does the work;
middleware wraps it with concerns like file mutation queueing, validation,
logging.

Coexists with Brute::Tools::* (which inherit from
[`Brute::Tool`](/brute/reference/brute/tool/)). Use a
[`ToolPipeline`](/brute/reference/brute/turn/tool-pipeline/) when you want
middleware; use [`Brute::Tool`](/brute/reference/brute/tool/) subclasses for
simple cases.


```ruby
read = Brute::Turn::ToolPipeline.new(
  name:        "read",
  description: "Read a file's contents",
  params:      { file_path: { type: "string", required: true } },
) do
  use Brute::Middleware::Tool::ValidateParams
  run ->(env) {
    env[:result] = File.read(File.expand_path(env[:arguments][:file_path]))
  }
end

read.call(file_path: "lib/brute.rb")
```

## Attributes

### description

`description` &mdash; read-only

*Not documented.*

### name

`name` &mdash; read-only

*Not documented.*

### params

`params` &mdash; read-only

*Not documented.*

## Class Methods

### self.new

```ruby
new(name:, description:, params: {}, &block)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(events: Pipeline::NullSink.new, **arguments)
```

*Not documented.*

## Defined in

- `lib/brute/turn/tool_pipeline.rb`
