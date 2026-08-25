---
title: "Brute::Tools::Adapter"
description: "Normalizes any tool shape into one neutral interface so the rest of Brute never has to care which tools library (if any) a tool was written with."
---


```ruby
module Brute::Tools
  class Adapter
  end
end
```

Normalizes any tool shape into one neutral interface so the rest of
[`Brute`](/brute/reference/brute/) never has to care which tools library (if
any) a tool was written with.

This solves three problems:

1.  Using any tools library — anything that quacks like a tool
    ([`#name`](/brute/reference/brute/tools/adapter/#name) plus
    [`#call`](/brute/reference/brute/tools/adapter/#call) or #execute) is
    wrapped into the same interface.
2.  Avoiding tool libraries entirely —
    [`Brute::Tool`](/brute/reference/brute/tool/),
    [`Brute::Turn::ToolPipeline`](/brute/reference/brute/turn/tool-pipeline/)
    and [`Tools::SubAgent`](/brute/reference/brute/tools/sub-agent/) work
    without inheriting from a library class.
3.  Quickly adding tools — a plain Hash with a proc is enough:


```ruby
Brute::Tools::Adapter.wrap(
  name:        "echo",
  description: "Echo the input back",
  params:      { msg: { type: "string", required: true } },
  execute:     ->(msg:) { msg },
)
```

The neutral interface:


```ruby
adapter.name        # String
adapter.description # String
adapter.params      # { key => { type:, desc:, required: } }
adapter.call(args)  # execute with a (string- or symbol-keyed) Hash
```

The inline `run` proc converts adapters (via
[`#to_h`](/brute/reference/brute/tools/adapter/#to_h)) into whatever its LLM
library expects; ToolPipeline executes them via
[`#call`](/brute/reference/brute/tools/adapter/#call).

## Attributes

### description

`description` &mdash; read-only

*Not documented.*

### name

`name` &mdash; read-only

*Not documented.*

### original

`original` &mdash; read-only

The tool object this adapter wraps
([`Brute::Tool`](/brute/reference/brute/tool/),
[`Brute::Turn::ToolPipeline`](/brute/reference/brute/turn/tool-pipeline/),
[`SubAgent`](/brute/reference/brute/tools/sub-agent/), Hash definition, ...).

### params

`params` &mdash; read-only

*Not documented.*

## Class Methods

### self.from_brute_tool

```ruby
from_brute_tool(tool)
```

A [`Brute::Tool`](/brute/reference/brute/tool/) instance.
[`Tools`](/brute/reference/brute/tools/) declared with the params({...})
schema DSL keep their full JSON schema.

### self.from_duck_type

```ruby
from_duck_type(tool)
```

Anything tool-shaped: needs
[`#name`](/brute/reference/brute/tools/adapter/#name) and
[`#call`](/brute/reference/brute/tools/adapter/#call) or #execute.

### self.from_hash

```ruby
from_hash(definition)
```

Quick inline tool: { name:, description:, params:, execute: }

### self.new

```ruby
new(name:, description:, params:, handler:, schema: nil, original: nil)
```

*Not documented.*

### self.wrap

```ruby
wrap(tool)
```

Wrap a single tool of any supported shape. Idempotent.

### self.wrap_all

```ruby
wrap_all(tools)
```

Wrap a list of tools into a { name_sym => adapter } lookup hash —the shape
ToolPipeline works with.

## Instance Methods

### #call

```ruby
call(arguments = {})
```

Execute the tool. Accepts string- or symbol-keyed argument hashes, as
delivered by LLM providers.

### #to_h

```ruby
to_h()
```

Library-neutral tool definition (JSON-Schema-ish). The inline `run` proc
reshapes this into whatever its LLM library expects.

## Defined in

- `lib/brute/tools/adapter.rb`
