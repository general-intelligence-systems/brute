---
title: "Brute::Tool"
description: "Base class for Brute's built-in tools — a tiny, framework-agnostic tool DSL."
---


```ruby
module Brute
  class Tool
  end
end
```

Base class for Brute's built-in tools — a tiny, framework-agnostic tool DSL.
It intentionally mirrors the common tool-library shape (description + params)
so tools read the same as they would in any LLM library, without depending on
one:


```ruby
class Shell < Brute::Tool
  description "Execute a shell command"
  param :command, type: 'string', desc: "The command", required: true

  def name; "shell"; end

  def execute(command:)
    ...
  end
end
```

For tools whose arguments don't fit the flat param list, pass a raw JSON
schema instead:


```
params({ type: 'object', properties: { ... }, required: [...] })
```

Instances expose the neutral interface
[`Brute::Tools::Adapter`](/brute/reference/brute/tools/adapter/) understands:
[`#name`](/brute/reference/brute/tool/#name),
[`#description`](/brute/reference/brute/tool/#description),
[`#params`](/brute/reference/brute/tool/#params),
[`#params_schema`](/brute/reference/brute/tool/#params_schema),
[`#call`](/brute/reference/brute/tool/#call).

## Class Methods

### self.description

```ruby
description(text = nil)
```

*Not documented.*

### self.param

```ruby
param(name, type: "string", desc: nil, required: true, **opts)
```

Declare one parameter: param :key, type:, desc:, required:

### self.param_definitions

```ruby
param_definitions()
```

*Not documented.*

### self.params

```ruby
params(schema = nil)
```

Raw JSON-schema override for complex argument shapes.

## Instance Methods

### #call

```ruby
call(arguments = {})
```

Execute with a string- or symbol-keyed argument hash, as delivered by LLM
providers.

### #description

```ruby
description()
```

*Not documented.*

### #execute

```ruby
execute(**)
```

*Not documented.*

### #name

```ruby
name()
```

[`Tool`](/brute/reference/brute/tool/) name; subclasses usually override with
an explicit short name.

### #params

```ruby
params()
```

{ key => { type:, desc:, required: } }

### #params_schema

```ruby
params_schema()
```

The raw JSON schema, when declared via params({...}).

## Defined in

- `lib/brute/tool.rb`
