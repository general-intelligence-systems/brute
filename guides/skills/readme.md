# Skills

A skill is a directory of specialized instructions for a kind of task — a debugging
workflow, a deployment checklist, a code-review procedure — that the agent pulls in
only when a task matches. Brute implements the [Agent Skills
specification](https://agentskills.io/specification) (originally Anthropic's, also
implemented by opencode), including its three-stage progressive-disclosure lifecycle.

The mechanism lives in three places:

- `lib/brute/skill.rb` — discovery, validation, parsing (`Brute::Skill`)
- `lib/brute/prompts/skills.rb` — the system-prompt listing (`Brute::Prompts::Skills`)
- `lib/brute/tools/skill_load.rb` — the `skill` tool (`Brute::Tools::SkillLoad`)

## The file format

A skill is a directory containing a `SKILL.md` with YAML frontmatter and a markdown body:

```markdown
---
name: debugging
description: Systematic debugging workflow for isolating and fixing bugs
---

When debugging, follow these steps...
```

A skill directory may also bundle resources the instructions refer to:

```
.brute/skills/debugging/
  SKILL.md
  scripts/bisect.sh
  references/checklist.md
```

### Frontmatter fields

| Field | Required | Rules |
|-------|----------|-------|
| `name` | yes* | 1–64 chars, lowercase, letters/digits/hyphens only, no leading/trailing/consecutive hyphens, **must match the directory name** |
| `description` | yes | 1–1024 chars, non-empty |
| `license` | no | free-form string |
| `compatibility` | no | string, ≤500 chars |
| `metadata` | no | arbitrary map |
| `allowed-tools` | no | experimental; space-separated tool names (parsed into `allowed_tools`, not yet enforced) |

\* `name` may be omitted, in which case it defaults to the directory name (which
trivially satisfies the directory-match rule).

A skill that violates a normative rule (bad `name`, missing/oversized `description`,
oversized `compatibility`) is **skipped with a stderr warning** naming the violated
rule — never raised. Unexpected frontmatter fields (e.g. `tags`) are a soft
violation: they are dropped with a warning, but the skill still loads, so the loader
tolerates vendor and forward extensions that real published skills carry. This is the
one intentional deviation from the [reference validator](https://github.com/agentskills/agentskills/tree/main/skills-ref),
which hard-fails on unknown fields.

## The three stages

Progressive disclosure keeps the context small no matter how many skills exist: the
model sees only metadata up front and pulls in the body, then the bundled resources,
on demand.

### Stage 1 — discovery (system prompt, ~100 tokens/skill)

`Brute::Prompts::Skills` scans for skills and injects **only** each skill's name and
description into the system prompt — never the body:

```
Skills provide specialized instructions and workflows for specific tasks.
Use the skill tool to load a skill when a task matches its description. ...

<available_skills>
  <skill>
    <name>debugging</name>
    <description>Systematic debugging workflow for isolating and fixing bugs</description>
  </skill>
</available_skills>
```

It scans two roots, project-local first (it overrides a same-named global skill):

1. `<cwd>/.brute/skills/**/SKILL.md`
2. `~/.config/brute/skills/**/SKILL.md`

### Stage 2 — activation (the `skill` tool)

When a task matches, the model calls the `skill` tool with the skill name. The tool
(`Brute::Tools::SkillLoad`) resolves the skill via `Brute::Skill.get` and returns the
full `SKILL.md` body, the skill's **base directory**, and a capped listing (up to 10)
of bundled files:

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

An unknown name returns a tool-error **string** (listing the available skill names),
consistent with brute's tool-error convention — it never raises.

### Stage 3 — execution (bundled resources via existing tools)

There is no separate skill runtime. The base directory and file listing from stage 2
let the model run or read bundled resources by relative path **through the agent's
existing tools** — `shell` to run `scripts/bisect.sh`, `read` to load
`references/checklist.md`. This is why the `skill` tool returns the directory, not
just the body.

## Keeping the tool and the prompt in sync

`Brute::Prompts::Skills` reads `ctx[:cwd]` (default `Dir.pwd`); `Brute::Tools::SkillLoad`
takes a `cwd:` at construction (default `Dir.pwd`). They must scan the same root, or
the prompt would advertise skills the tool cannot load. With the defaults they agree.
An agent that points the prompt at a custom root must build the tool with the matching
`cwd`:

```ruby
SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, ctx|
  # ...
  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: __dir__))
  prompt << skills if skills
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL.map { |t| t == Brute::Tools::SkillLoad ? Brute::Tools::SkillLoad.new(cwd: __dir__) : t },
) { ... }
```

`Brute::Tools::ALL` includes `SkillLoad` (as the class, so it resolves to the default
`Dir.pwd`), and `Prompts::Skills` is in the default `anthropic`, `openai`, `google`,
and `default` system-prompt stacks. The `ollama` stack omits it to keep prompts lean.

## Follow-ups (not yet implemented)

- `allowed-tools` enforcement (fits the tool-middleware allowlist work).
- Remote/URL skill sources and a registry index.
- Per-agent skill permissions.
