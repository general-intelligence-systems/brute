---
layout: default
title: Skills
nav_order: 3
description: 'Skills are markdown instruction files discovered from the filesystem and surfaced to the model with progressive disclosure.'
---

# Skills

A skill is a `SKILL.md` file of specialized instructions for a kind of task — a debugging workflow, a release checklist, a code-review procedure. Skills are not code; they are prompt material, discovered from the filesystem and surfaced to the model so it can pull in detailed guidance only when a task matches.

Brute implements the [Agent Skills specification](https://agentskills.io/specification) and its three-stage progressive-disclosure lifecycle.

## The file format

A skill is a directory whose `SKILL.md` has YAML frontmatter and a markdown body:

```markdown
---
name: debugging
description: Systematic debugging workflow for isolating and fixing bugs
---

When debugging, follow these steps...
```

- `name`: 1–64 chars, lowercase letters/digits/hyphens, and must match the parent directory name (defaults to the directory name if omitted).
- `description`: **required**, 1–1024 chars.
- Optional: `license`, `compatibility`, `metadata`, `allowed-tools`.

A skill that violates a rule is **skipped with a stderr warning** — never raised. Unexpected fields are dropped with a warning but the skill still loads, so real-world skills carrying vendor extensions still work.

## Discovery

`Brute::Skill.all(cwd:)` scans two roots, in priority order:

1. `<cwd>/.brute/skills/**/SKILL.md` — project-local
2. `~/.config/brute/skills/**/SKILL.md` — global (per-user)

```
.brute/skills/
  debugging/SKILL.md
  release-checklist/SKILL.md
```

When two skills share a name, first found wins, so a project-local skill overrides a same-named global one.

## The three stages

**1. Names and descriptions in the system prompt.** `Brute::Prompts::Skills` injects only each skill's name and description — not the body — so the prompt stays small no matter how many skills exist:

```
<available_skills>
  <skill>
    <name>debugging</name>
    <description>Systematic debugging workflow for isolating and fixing bugs</description>
  </skill>
</available_skills>
```

This is part of the default system-prompt stack for the `anthropic`, `openai`, `google`, and `default` providers. The `ollama` stack omits it to keep prompts lean for small local models.

**2. Loading the body via the `skill` tool.** When the model decides a skill applies, it calls the `skill` tool (`Brute::Tools::SkillLoad`) with the name. The tool returns the full `SKILL.md` body plus the skill's base directory and a sample of its bundled files:

```
<skill name="debugging">
# Skill: debugging

When debugging, follow these steps...

Base directory for this skill: /project/.brute/skills/debugging
Bundled files (sampled, up to 10):
  references/checklist.md
  scripts/bisect.sh
</skill>
```

**3. Bundled resources through existing tools.** Skills can ship `scripts/`, `references/`, and `assets/`. There is no separate skill runtime — the model reads and runs them by relative path through the agent's ordinary `read` and `shell` tools.

An unknown skill name returns a tool-error string listing the available names; it never raises.

## Using skills in your own agent

`Prompts::Skills` is just another prompt module, so custom agents opt in by appending it when building a system prompt:

```ruby
sp = Brute::SystemPrompt.build do |prompt, ctx|
  prompt << Brute::Prompts::Identity.call(ctx)
  prompt << Brute::Prompts::Skills.call(ctx)   # scans ctx[:cwd] for skills
end

Brute.agent.use(Brute::Middleware::SystemPrompt, system_prompt: sp)
```

The `skill` tool takes a matching `cwd:` at construction — point both the prompt and the tool at the same root, or the prompt advertises skills the tool can't load. `Brute::Tools::ALL` includes it with the default `Dir.pwd`.

A skill's body is also available programmatically: `Brute::Skill.get("debugging").content`.
