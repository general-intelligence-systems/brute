---
title: "Brute::PromptTemplate"
description: "An ERB-backed system-prompt object for Middleware::SystemPrompt — the open alternative to Brute::SystemPrompt's built-in section stacks."
---


```ruby
module Brute
  class PromptTemplate
  end
end
```

An ERB-backed system-prompt object for
[`Middleware::SystemPrompt`](/brute/reference/brute/middleware/system-prompt/)
— the open alternative to
[`Brute::SystemPrompt`](/brute/reference/brute/system-prompt/)'s built-in
section stacks. You bring a template and named values; every keyword becomes
an attr_accessor and an ERB local of the same name:


```ruby
prompt = Brute::PromptTemplate.new(
  "prompt.erb",
  identity: "You are Pico.",
  memory:   -> { File.read("memory/MEMORY.md") },   # zero-arity proc
  env:      ->(ctx) { Brute::Prompts::Environment.call(ctx) },
)
prompt.identity = "You are Brute."   # attr_accessor per section

Brute.agent.use(Brute::Middleware::SystemPrompt, system_prompt: prompt)
```

Proc values are re-evaluated on every prepare (zero-arity procs are called
with no arguments, others receive the turn ctx), and a template path is
re-read from disk each time — so file-backed sections hot-reload between
turns. The prepare(ctx) -> Result(#empty?, #to_s) contract is what
[`Middleware::SystemPrompt`](/brute/reference/brute/middleware/system-prompt/)
expects.

## Constants

### Result

```ruby
Result = Struct.new(:text) do
      def to_s = text.to_s
      def empty? = text.to_s.strip.empty?
    end
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(template, **sections)
```

*Not documented.*

## Instance Methods

### #[]

```ruby
[](key)
```

*Not documented.*

### #[]=

```ruby
[]=(key, value)
```

*Not documented.*

### #prepare

```ruby
prepare(ctx = {})
```

Called once per turn by
[`Middleware::SystemPrompt`](/brute/reference/brute/middleware/system-prompt/)
.

## Defined in

- `lib/brute/prompt_template.rb`
