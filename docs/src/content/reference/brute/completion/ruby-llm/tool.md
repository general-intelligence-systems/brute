---
title: "Brute::Completion::RubyLLM::Tool"
description: "A Brute tool adapter wearing the interface ruby_llm's providers read off a RubyLLM::Tool: name, description, and a params_schema (they fall back to #paramete..."
---


```ruby
module Brute::Completion::RubyLLM
  class Tool
  end
end
```

A [`Brute`](/brute/reference/brute/) tool adapter wearing the interface
ruby_llm's providers read off a
[`RubyLLM::Tool`](/brute/reference/brute/completion/ruby-llm/tool/): name,
description, and a
[`params_schema`](/brute/reference/brute/completion/ruby-llm/tool/#params_sche
ma) (they fall back to
[`#parameters`](/brute/reference/brute/completion/ruby-llm/tool/#parameters)
only when that is nil), plus
[`#provider_params`](/brute/reference/brute/completion/ruby-llm/tool/#provider
_params) to deep-merge into the declaration. Brute's own ToolPipeline runs the
tool, so this mostly has to describe it —
[`#call`](/brute/reference/brute/completion/ruby-llm/tool/#call) is here for a
caller that hands the same list to ruby_llm's dispatch.

## Class Methods

### self.new

```ruby
new(adapter)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(args)
```

*Not documented.*

### #description

```ruby
description()
```

*Not documented.*

### #name

```ruby
name()
```

*Not documented.*

### #parameters

```ruby
parameters()
```

*Not documented.*

### #params_schema

```ruby
params_schema()
```

*Not documented.*

### #provider_params

```ruby
provider_params()
```

*Not documented.*

## Defined in

- `lib/brute/completion/ruby_llm.rb`
