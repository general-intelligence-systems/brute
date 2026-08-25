---
title: "Brute::SystemPrompt"
description: "Deferred system prompt builder."
---


```ruby
module Brute
  class SystemPrompt
  end
end
```

Deferred system prompt builder.

The block passed to `build` is stored — not executed — until `prepare` is
called with a runtime context hash (provider_name, model_name, cwd, etc).


```ruby
sp = Brute::SystemPrompt.build do |prompt, ctx|
  prompt.append Brute::Prompts::Identity.call(ctx)
  prompt.append Brute::Prompts::ToneAndStyle.call(ctx)
  prompt.append Brute::Prompts::Environment.call(ctx)
end

result = sp.prepare(provider_name: "anthropic", model_name: "claude-sonnet-4-20250514", cwd: Dir.pwd)
result.to_s       # single joined string
result.sections   # array of strings (one per p.system call)
```

## Constants

### Result

```ruby
Result = Struct.new(:sections) do
      def to_s
        sections.join("\n\n")
      end

      def each(&block)
        sections.each(&block)
      end

      def empty?
        sections.empty?
      end
    end
```

Immutable result of a prepared system prompt.

### STACKS

```ruby
STACKS = {
      # Claude — full-featured with task management and detailed tool policy
      "anthropic" => [
        Prompts::Identity,
        Prompts::ToneAndStyle,
        Prompts::Objectivity,
        Prompts::TaskManagement,
        Prompts::DoingTasks,
        Prompts::ToolUsage,
        Prompts::Conventions,
        Prompts::GitSafety,
        Prompts::CodeReferences,
        Prompts::Environment,
        Prompts::Skills,
        Prompts::Instructions,
      ],

      # GPT-4 / o1 / o3 — pragmatic engineer persona, editing focus, autonomy
      "openai" => [
        Prompts::Identity,
        Prompts::EditingApproach,
        Prompts::Autonomy,
        Prompts::EditingConstraints,
        Prompts::FrontendTasks,
        Prompts::ToneAndStyle,
        Prompts::Conventions,
        Prompts::GitSafety,
        Prompts::CodeReferences,
        Prompts::Environment,
        Prompts::Skills,
        Prompts::Instructions,
      ],

      # Gemini — formal/structured, explicit workflows, security focus
      "google" => [
        Prompts::Identity,
        Prompts::Conventions,
        Prompts::DoingTasks,
        Prompts::ToneAndStyle,
        Prompts::SecurityAndSafety,
        Prompts::ToolUsage,
        Prompts::GitSafety,
        Prompts::CodeReferences,
        Prompts::Environment,
        Prompts::Skills,
        Prompts::Instructions,
      ],

      # Ollama — lean stack for local models with smaller context windows
      "ollama" => [
        Prompts::Identity,
        Prompts::ToneAndStyle,
        Prompts::Conventions,
        Prompts::DoingTasks,
        Prompts::ToolUsage,
        Prompts::GitSafety,
        Prompts::Environment,
        Prompts::Instructions,
      ],

      # Fallback — conservative, concise, fewer than 4 lines
      "default" => [
        Prompts::Identity,
        Prompts::ToneAndStyle,
        Prompts::Proactiveness,
        Prompts::Conventions,
        Prompts::CodeStyle,
        Prompts::DoingTasks,
        Prompts::ToolUsage,
        Prompts::GitSafety,
        Prompts::CodeReferences,
        Prompts::Environment,
        Prompts::Skills,
        Prompts::Instructions,
      ],
    }.freeze
```

Pre-configured prompt stacks per provider. Each maps a provider name to an
ordered list of prompt modules.

## Class Methods

### self.build

```ruby
build(&block)
```

Build a deferred system prompt. The block is stored and called later by
`prepare`.

### self.default

```ruby
default()
```

Return the default system prompt. Selects the right provider stack at
prepare-time, then appends conditional sections based on runtime state.

### self.infer_stack_from_model

```ruby
infer_stack_from_model(model_name)
```

Infer the best prompt stack from a model name. Used for gateway providers that
route to multiple upstream model families.

### self.new

```ruby
new(block)
```

*Not documented.*

## Instance Methods

### #prepare

```ruby
prepare(ctx)
```

Execute the stored block with the given context and return a
[`Result`](/brute/reference/brute/system-prompt/#result).

## Defined in

- `lib/brute/system_prompt.rb`
