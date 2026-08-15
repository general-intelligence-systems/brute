---
name: skill-creator
description: Create, validate, and install agent skills - both markdown skills and kernel-backed skills callable from the IRuby kernel. Use when the user asks to create a skill, turn a workflow, script, or prompt into a reusable skill, or asks how to write a SKILL.md and where skills live.
---

# Skill Creator

SCAFFOLD — instruction-only port of prime-agent
`packages/coding-agent/skills/skill-creator`. Fill-in: adapt the upstream
SKILL.md body and `references/` to this port (paths `.brute/skills/`,
kernel-backed skills carry a `lib/` dir the bootstrap globs onto the load
path); see FEATURES.md (S5).

A skill is a directory with a `SKILL.md` file (YAML frontmatter + markdown
instructions). At startup only each skill's name and description enter the
system prompt; the full file loads on demand when a task matches.

- Locations: `<cwd>/.brute/skills/<name>/` (project) or `~/.brute/skills/<name>/` (global).
- Frontmatter `name` + `description` are required — a missing description
  silently drops the skill from the prompt.
- Kernel-backed skills add `lib/<import_name>.rb`; the kernel bootstrap puts
  every skill's `lib/` on the load path, so cells can
  `require "<import_name>"` and call its module functions (see the `edit`
  skill for the contract).
