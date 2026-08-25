---
title: "Brute::Tools::SkillLoad"
description: "The skill tool — stages 2 (activation) and 3 (execution) of the Agent Skills progressive-disclosure lifecycle (https://agentskills.io)."
---


```ruby
module Brute::Tools
  class SkillLoad < Brute::Tool
  end
end
```

The `skill` tool — stages 2 (activation) and 3 (execution) of the Agent Skills
progressive-disclosure lifecycle (https://agentskills.io).

Stage 1 (discovery) happens in the system prompt:
[`Brute::Prompts::Skills`](/brute/reference/brute/prompts/skills/) lists each
skill's name + description only (~100 tokens each). When a task matches, the
model calls this tool with the skill name to pull the full SKILL.md body into
the conversation (stage 2).

The output also reports the skill's base directory and a capped listing of
bundled files. That is stage 3: skills bundle scripts/, references/, and
assets/ that the model runs or reads *through the agent's existing tools*
(`shell`, `read`) by relative path. There is no separate skill runtime.

The tool must scan the same directories as
[`Prompts::Skills`](/brute/reference/brute/prompts/skills/), or it would
advertise skills it cannot load. Both default to Dir.pwd; agents that point
the prompt at a custom root (e.g. ctx.merge(cwd: __dir__)) should build the
tool with the matching cwd:
[`Brute::Tools::SkillLoad.new`](/brute/reference/brute/tools/skill-load/#selfn
ew)(cwd: __dir__).

Reference: opencode's tool/skill.ts.

## Constants

### FILE_LIMIT

```ruby
FILE_LIMIT = 10
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(cwd: Dir.pwd)
```

*Not documented.*

## Instance Methods

### #execute

```ruby
execute(name:)
```

*Not documented.*

### #name

```ruby
name()
```

*Not documented.*

## Defined in

- `lib/brute/tools/skill_load.rb`
