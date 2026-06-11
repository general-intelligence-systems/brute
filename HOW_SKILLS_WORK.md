# How Skills Work

A skill is a markdown file (`SKILL.md`) containing specialized instructions for a
specific kind of task — a debugging workflow, a deployment checklist, a code-review
procedure. Skills are not code: they are prompt material, discovered from the
filesystem and surfaced to the model so it can pull in detailed guidance when a task
matches.

The entire mechanism lives in two files:

- `lib/brute/skill.rb` — discovery, parsing, formatting (`Brute::Skill`)
- `lib/brute/prompts/skills.rb` — the system-prompt section (`Brute::Prompts::Skills`)

## The file format

A skill is a directory containing a `SKILL.md` with YAML frontmatter followed by a
markdown body:

```markdown
---
name: debugging
description: Systematic debugging workflow for isolating and fixing bugs
---

When debugging, follow these steps...
```

Parsing rules (`Brute::Skill.load`, `lib/brute/skill.rb:70`):

- `description` is **required** — a skill without one (or with a blank one) is
  silently skipped.
- `name` is optional — it defaults to the name of the directory containing
  `SKILL.md` (`lib/brute/skill.rb:75`).
- The body (everything after the frontmatter) is the skill's content.
- A file that fails to parse logs a warning to stderr and is skipped rather than
  raising (`lib/brute/skill.rb:85-87`).

Each loaded skill becomes a `Skill::Info` struct with four fields: `name`,
`description`, `location` (the file path), and `content` (the body).

## Discovery

`Brute::Skill.all(cwd:)` scans two locations, in priority order
(`lib/brute/skill.rb:91-103`):

1. `<cwd>/.brute/skills/**/SKILL.md` — project-local
2. `~/.config/brute/skills/**/SKILL.md` — global (per-user)

The glob is recursive, so skills can be nested arbitrarily deep under either root —
the convention is one directory per skill:

```
.brute/skills/
  debugging/SKILL.md
  release-checklist/SKILL.md
```

When two skills share a name, **first found wins** (`lib/brute/skill.rb:41`), so a
project-local skill overrides a same-named global one. Results are deduplicated by
name and returned sorted alphabetically.

`Brute::Skill.get(name, cwd:)` fetches a single skill by name through the same scan.

## How skills reach the model

Skills use a progressive-disclosure design: only the **name and description** of
each skill are injected into the system prompt, not the body. This keeps the prompt
small no matter how many skills exist; the model fetches full instructions only when
it needs them.

`Brute::Prompts::Skills.call(ctx)` (`lib/brute/prompts/skills.rb`) runs at
prompt-preparation time:

1. It scans for skills using `ctx[:cwd]` (defaulting to `Dir.pwd`).
2. If none are found, it returns `nil` — the section is dropped entirely
   (`SystemPrompt::Result` rejects nil/empty sections, `lib/brute/system_prompt.rb:163`).
3. Otherwise it emits a short usage instruction plus an XML listing built by
   `Brute::Skill.fmt` (`lib/brute/skill.rb:54`):

```
Skills provide specialized instructions and workflows for specific tasks.
When a task matches a skill's description, load the skill to get detailed guidance.

<available_skills>
  <skill>
    <name>debugging</name>
    <description>Systematic debugging workflow for isolating and fixing bugs</description>
  </skill>
</available_skills>
```

`Prompts::Skills` is part of the default system-prompt stacks for the `anthropic`,
`openai`, `google`, and `default` providers (`lib/brute/system_prompt.rb:63-138`).
The `ollama` stack deliberately omits it to keep prompts lean for small-context
local models.

## Loading a skill's body

There is no dedicated "skill" tool. When the model decides a skill applies, it loads
the body itself using the ordinary `read` tool against the conventional path
(`.brute/skills/<name>/SKILL.md`). Programmatically, the body is also available as
`Brute::Skill.get("debugging").content`, e.g. if you want to inject a skill's full
text into a prompt yourself.

## Using skills in your own agent

Because `Prompts::Skills` is just another prompt module, custom agents opt in by
appending it when building a system prompt. The dexter port does exactly this
(`examples/ports/dexter/agent.rb:79-80`):

```ruby
sp = Brute::SystemPrompt.build do |prompt, ctx|
  prompt << Brute::Prompts::Identity.call(ctx)
  # ...
  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: __dir__))
  prompt << skills if skills
end
```

Passing a custom `cwd` points discovery at a different project root — here, the
example's own directory, so it picks up `examples/ports/dexter/.brute/skills/`.

## Summary of the flow

```
.brute/skills/**/SKILL.md            ~/.config/brute/skills/**/SKILL.md
        └──────────────┬──────────────────────┘
                Brute::Skill.all          (parse frontmatter, dedupe, sort)
                       │
              Brute::Prompts::Skills      (system-prompt section)
                       │
            <available_skills> listing    (names + descriptions only)
                       │
            model matches task → reads SKILL.md with the read tool
                       │
            full instructions enter the conversation as a tool result
```
