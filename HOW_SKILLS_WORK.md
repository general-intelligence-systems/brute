# How Skills Work

A skill is a markdown file (`SKILL.md`) containing specialized instructions for a
specific kind of task — a debugging workflow, a deployment checklist, a code-review
procedure. Skills are not code: they are prompt material, discovered from the
filesystem and surfaced to the model so it can pull in detailed guidance when a task
matches.

Brute implements the [Agent Skills specification](https://agentskills.io/specification)
and its three-stage progressive-disclosure lifecycle. The mechanism lives in three files:

- `lib/brute/skill.rb` — discovery, validation, parsing, formatting (`Brute::Skill`)
- `lib/brute/prompts/skills.rb` — the system-prompt section (`Brute::Prompts::Skills`)
- `lib/brute/tools/skill_load.rb` — the `skill` tool (`Brute::Tools::SkillLoad`)

For the full reference (frontmatter rules, the three stages, cwd syncing), see
`guides/skills/readme.md`. This file is the narrative walkthrough.

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

Parsing and validation (`Brute::Skill.load`) mirror the spec's reference validator:

- `name`: 1–64 chars, lowercase, letters/digits/hyphens only, no leading/trailing or
  consecutive hyphens, and **must match the parent directory name**. It may be omitted,
  in which case it defaults to the directory name.
- `description`: **required**, non-empty, 1–1024 chars.
- Optional fields are parsed instead of dropped: `license`, `compatibility` (≤500
  chars), `metadata` (map), `allowed-tools` (experimental, space-separated → `allowed_tools`).
- A skill that violates a normative rule is **skipped with a stderr warning naming the
  rule** — never raised. Unexpected fields (e.g. `tags`) are dropped with a warning but
  the skill still loads (a deliberate deviation from the reference validator, which
  hard-fails, so brute tolerates the vendor extensions real skills carry).

Each loaded skill becomes a `Skill::Info` struct: `name`, `description`, `location`
(the file path), `content` (the body), `license`, `compatibility`, `metadata`, and
`allowed_tools`.

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

## Loading a skill's body — the `skill` tool

When the model decides a skill applies, it calls the `skill` tool
(`Brute::Tools::SkillLoad`, `lib/brute/tools/skill_load.rb`) with the skill name. The
tool resolves it via `Brute::Skill.get` and returns the full `SKILL.md` body, the
skill's **base directory**, and a capped listing (up to 10) of bundled files:

```
<skill name="debugging">
# Skill: debugging

When debugging, follow these steps...

Base directory for this skill: /project/.brute/skills/debugging
Relative paths in this skill (e.g. scripts/, references/, assets/) are relative to
this base directory. Use your existing tools (read, shell) to access them.

Bundled files (sampled, up to 10):
  references/checklist.md
  scripts/bisect.sh
</skill>
```

The directory + file listing is the spec's third stage: skills bundle `scripts/`,
`references/`, and `assets/` that the model then runs or reads **through the agent's
existing tools** (`shell`, `read`) by relative path. There is no separate skill
runtime. An unknown name returns a tool-error string listing the available names — it
never raises.

The tool takes a `cwd:` at construction (default `Dir.pwd`) and must scan the same
root as `Prompts::Skills`, or it would advertise skills it can't load. `Brute::Tools::ALL`
includes it as the class (default `Dir.pwd`); agents that point the prompt at a custom
root build the tool with the matching `cwd`.

Programmatically, the body is also available as `Brute::Skill.get("debugging").content`,
e.g. if you want to inject a skill's full text into a prompt yourself.

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
            model matches task → calls the `skill` tool (SkillLoad)
                       │
            tool returns body + base dir + file listing (enters as a tool result)
                       │
            model runs/reads bundled resources via shell/read (relative paths)
```
