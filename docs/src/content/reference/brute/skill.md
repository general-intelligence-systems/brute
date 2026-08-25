---
title: "Brute::Skill"
description: "A single skill: metadata plus the address of its SKILL.md on disk."
---


```ruby
module Brute
  class Skill
  end
end
```

A single skill: metadata plus the address of its SKILL.md on disk.

A skill is a directory containing a SKILL.md markdown file with YAML
frontmatter:


```
---
name: debugging
description: Systematic debugging workflow for isolating and fixing bugs
---

When debugging, follow these steps...
```

The object is a value object — it carries the parsed frontmatter, the body,
and the file location, nothing else. Modeled on prime-agent's BaseSkill
(packages/coding-agent/src/core/skills.ts).

Discovery is class-level and caller-side:
[`Skill.all`](/brute/reference/brute/skill/#selfall) scans (in order)

```
1. <cwd>/.brute/skills/**/SKILL.md   (project-local, :project)
2. ~/.config/brute/skills/**/SKILL.md (global, :user)
3. explicit paths: (dirs or .md files, :path)
```

First found wins on name collisions (with a stderr warning naming winner and
loser), and the same file reached twice via symlinks is skipped.

Parsing and validation mirror the Agent Skills specification
(https://agentskills.io/specification). A skill whose frontmatter violates a
rule is skipped with a stderr warning naming the rule — never raised.

## Constants

### ALLOWED_FIELDS

```ruby
ALLOWED_FIELDS = %w[name description license allowed-tools metadata compatibility disable-model-invocation].freeze
```

Frontmatter keys permitted by the spec. Anything else is a violation.

### FILENAME

```ruby
FILENAME = "SKILL.md"
```

*Not documented.*

### MAX_COMPATIBILITY_LENGTH

```ruby
MAX_COMPATIBILITY_LENGTH = 500
```

*Not documented.*

### MAX_DESCRIPTION_LENGTH

```ruby
MAX_DESCRIPTION_LENGTH = 1024
```

*Not documented.*

### MAX_NAME_LENGTH

```ruby
MAX_NAME_LENGTH = 64
```

*Not documented.*

## Attributes

### allowed_tools

`allowed_tools` &mdash; read-only

*Not documented.*

### base_dir

`base_dir` &mdash; read-only

*Not documented.*

### compatibility

`compatibility` &mdash; read-only

*Not documented.*

### content

`content` &mdash; read-only

*Not documented.*

### description

`description` &mdash; read-only

*Not documented.*

### file_path

`file_path` &mdash; read-only

*Not documented.*

### license

`license` &mdash; read-only

*Not documented.*

### metadata

`metadata` &mdash; read-only

*Not documented.*

### name

`name` &mdash; read-only

*Not documented.*

### source

`source` &mdash; read-only

*Not documented.*

## Class Methods

### self.all

```ruby
all(cwd: Dir.pwd, paths: [])
```

Scan all skill directories and return an array of Skills, sorted by name.

Precedence is first-found-wins: project-local overrides global overrides
explicit paths. Name collisions warn to stderr naming winner and loser; the
same file reached via different symlinks is loaded only once.

### self.get

```ruby
get(name, cwd: Dir.pwd, paths: [])
```

Get a single skill by name through the same scan as .all.

### self.load

```ruby
load(path, source: :path)
```

Parse and validate a SKILL.md file into a
[`Skill`](/brute/reference/brute/skill/). Returns nil (with a stderr warning)
if the file is invalid.

### self.new

```ruby
new(name:, description:, file_path:, content: nil, source: :path, license: nil, compatibility: nil, metadata: nil, allowed_tools: nil, disable_model_invocation: false)
```

*Not documented.*

## Instance Methods

### #disable_model_invocation?

```ruby
disable_model_invocation?()
```

Hidden from the prompt listing (explicit invocation only), but still handed to
the agent as an object.

### #location

```ruby
location()
```

Back-compat alias
([`Tools::SkillLoad`](/brute/reference/brute/tools/skill-load/) era).

## Defined in

- `lib/brute/skill.rb`
