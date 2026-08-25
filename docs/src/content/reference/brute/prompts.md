---
title: "Brute::Prompts"
description: "Module Brute::Prompts."
---


```ruby
module Brute
  module Prompts
  end
end
```

## Constants

### TEMPLATES

```ruby
TEMPLATES = {}
```

Compiled templates, keyed by absolute path. Compilation is idempotent, so a
racy double-assign under Async is harmless.

### TEXT_DIR

```ruby
TEXT_DIR = File.expand_path("text", __dir__)
```

*Not documented.*

## Class Methods

### self.agent_prompt

```ruby
agent_prompt(name)
```

Read a named agent prompt (e.g. "explore", "compaction").

### self.read

```ruby
read(section, provider_name)
```

Resolve a provider-specific text file. Looks for
<code>section/provider_name.txt</code>, falls back to
<code>section/default.txt</code>.

### self.render

```ruby
render(section, ctx)
```

Resolve and render text/<section>/<provider>.erb, falling back to default.erb,
then to the legacy plain .txt files. Returns nil when the section has no
template or text file at all.

Templates are ERB: arbitrary Ruby. Only ship templates with the gem or load
them from paths you trust.

## Defined in

- `lib/brute/prompts.rb`
- `lib/brute/prompts/autonomy.rb`
- `lib/brute/prompts/base.rb`
- `lib/brute/prompts/build_switch.rb`
- `lib/brute/prompts/code_references.rb`
- `lib/brute/prompts/code_style.rb`
- `lib/brute/prompts/conventions.rb`
- `lib/brute/prompts/doing_tasks.rb`
- `lib/brute/prompts/editing_approach.rb`
- `lib/brute/prompts/editing_constraints.rb`
- `lib/brute/prompts/environment.rb`
- `lib/brute/prompts/frontend_tasks.rb`
- `lib/brute/prompts/git_safety.rb`
- `lib/brute/prompts/identity.rb`
- `lib/brute/prompts/instructions.rb`
- `lib/brute/prompts/max_steps.rb`
- `lib/brute/prompts/objectivity.rb`
- `lib/brute/prompts/plan_reminder.rb`
- `lib/brute/prompts/proactiveness.rb`
- `lib/brute/prompts/security_and_safety.rb`
- `lib/brute/prompts/skills.rb`
- `lib/brute/prompts/task_management.rb`
- `lib/brute/prompts/tone_and_style.rb`
- `lib/brute/prompts/tool_usage.rb`
