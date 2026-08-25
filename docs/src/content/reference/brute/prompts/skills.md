---
title: "Brute::Prompts::Skills"
description: "The <available_skills> system-prompt section."
---


```ruby
module Brute::Prompts
  module Skills
  end
end
```

The <available_skills> system-prompt section.

Uses skill objects from `ctx[:skills]` when present (handed in via
[`Brute::Middleware::Skills`](/brute/reference/brute/middleware/skills/) ->
`env[:metadata]`[:skills]); falls back to scanning from `ctx[:cwd]` so the
default stacks keep working unwired.
[`Skills`](/brute/reference/brute/prompts/skills/) with
disable_model_invocation? are loaded but hidden here. Returns nil when no
skills are visible, dropping the section entirely.

## Class Methods

### self.call

```ruby
call(ctx)
```

*Not documented.*

## Defined in

- `lib/brute/prompts/skills.rb`
