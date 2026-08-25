---
title: "Brute::Middleware::Skills"
description: "Loads skill objects into the agent context."
---


```ruby
module Brute::Middleware
  class Skills < Base
  end
end
```

Loads skill objects into the agent context.

[`Skills`](/brute/reference/brute/middleware/skills/) are handed in as objects
— discovery is the caller's job:


```ruby
skills = Brute::Skill.all(cwd: Dir.pwd)
agent
  .use(Brute::Middleware::Skills, skills: skills)
  .use(Brute::Middleware::SystemPrompt)
```

Per turn:

```
1. env[:skills] = the objects, for downstream middleware, tools, and
   the terminal app (prime-agent's resourceLoader.getSkills() analogue)
2. env[:metadata][:skills] = the same objects, so
   Middleware::SystemPrompt merges them into the prompt ctx and
   Brute::Prompts::Skills renders the <available_skills> section
```

Place it before
[`Middleware::SystemPrompt`](/brute/reference/brute/middleware/system-prompt/)
in the stack. It never touches `env[:messages]` itself.

## Class Methods

### self.new

```ruby
new(app, skills: [])
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/025_skills.rb`
