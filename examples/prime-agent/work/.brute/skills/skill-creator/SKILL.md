---
name: skill-creator
description: Create, validate, and install agent skills - both markdown skills and kernel-backed skills callable from the IRuby kernel. Use when the user asks to create a skill, turn a workflow, script, or prompt into a reusable skill, or asks how to write a SKILL.md and where skills live.
---

# Skill Creator

A skill is a directory with a `SKILL.md` file (YAML frontmatter + markdown
instructions). At startup only each skill's name and description enter the
system prompt; the full file loads on demand when a task matches. This port
follows the [Agent Skills standard](https://agentskills.io/specification)
and extends it with kernel-backed (Ruby) skills.

| Kind | What it is | When to use |
|---|---|---|
| markdown | `SKILL.md` plus optional scripts, references, and assets | Workflows, CLI recipes, domain knowledge, multi-step instructions |
| ruby | A markdown skill that also ships Ruby code on the IRuby kernel load path | Capabilities that are naturally one call: API wrappers, fetchers, converters, computations |

Before writing a kernel-backed skill, read
[references/ruby-skills.md](references/ruby-skills.md) for the package
contract.

## Creating a Skill

1. **Pick the kind.** Default to markdown. Go Ruby only when the agent
   should *call* the capability (`Edit.run(...)`) instead of following
   instructions.
2. **Pick the location.** Ask the user when it is not obvious from context:
   - Project skill, shared via the repo: `.brute/skills/<name>/`
   - Personal global skill: `~/.brute/skills/<name>/`
3. **Scaffold and write** the directory using the layout and frontmatter
   rules below.
4. **Verify** the skill loads (see Verification).

On a name collision the first skill found wins. Precedence: project, then
global.

## Layout

```
my-skill/
├── SKILL.md              # Required: frontmatter + instructions
├── lib/                  # Optional: ruby files on the kernel load path
├── scripts/              # Optional helper scripts the instructions reference
├── references/           # Optional detailed docs, loaded only when needed
└── assets/               # Optional templates and data files
```

Everything except `SKILL.md` is freeform. Reference files with paths
relative to the skill directory; the agent resolves them against the
directory containing `SKILL.md`.

## Frontmatter

```markdown
---
name: my-skill
description: What this skill does and when to use it. Be specific.
---
```

| Field | Required | Rules |
|---|---|---|
| `name` | Yes | Max 64 chars. Lowercase a-z, 0-9, hyphens. No leading/trailing/consecutive hyphens. Must match the parent directory name. |
| `description` | Yes | Max 1024 chars. A skill with a missing or empty description is **silently not loaded**. |
| `disable-model-invocation` | No | `true` hides the skill from the system prompt. |
| `license` | No | License name or reference to a bundled file. |
| `compatibility` | No | Max 500 chars. Environment requirements. |
| `metadata` | No | Arbitrary key-value mapping. |

Unknown fields are ignored.

### Write the description for routing

The description is the only thing the model sees before deciding to load the
skill. State what the skill does *and* the trigger conditions ("Use when
..."), naming the concrete tasks, tools, and phrases a request would contain.

Good: `Extracts text and tables from PDF files, fills PDF forms, and merges PDFs. Use when working with PDF documents.`
Poor: `Helps with PDFs.`

### Write the body for progressive disclosure

Keep `SKILL.md` short: the decision flow, the common commands, the contract.
Push exhaustive detail (API schemas, full option lists, long examples) into
`references/*.md` and link them, so they only enter context when actually
needed. State setup steps (installs, env vars, credentials) explicitly and
early.

## Verification

After writing the skill:

1. Re-read the frontmatter and check every rule in the table above,
   especially that `name` matches the directory name and the description is
   non-empty.
2. Restart the run — skills are scanned into the system prompt at boot (the
   prompt refreshes each turn, so a new skill appears on the next turn of a
   running session).
3. Kernel-backed skills: confirm the `lib/` file loads by calling it from a
   cell (`require "my_skill"; MySkill.run(...)`).

For kernel-backed skills, also run the checks in
[references/ruby-skills.md](references/ruby-skills.md).
