# Superpowers Dev Shop

A disciplined software development company powered by the Superpowers workflow — brainstorm, plan, build with TDD, review, and ship. A **team of 4 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`superpowers`](https://github.com/paperclipai/companies/tree/main/superpowers)). Authored upstream by Jesse Vincent.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (brainstorming, writing-plans, using-superpowers)
├─► code-reviewer  (requesting-code-review, receiving-code-review, verification-before-completion)
├─► lead-engineer  (test-driven-development, subagent-driven-development, executing-plans, using-git-worktrees, dispatching-parallel-agents, systematic-debugging)
└─► release-engineer  (finishing-a-development-branch)
```

## Layout

| Path | Role |
|------|------|
| `team.rb` | wiring (run this) |
| `COMPANY.md` | upstream company manifest, verbatim |
| `agents/<name>/AGENTS.md` | upstream role definitions, verbatim |
| `agents/<name>/.brute/skills/` | each member's skills, verbatim |

## Usage

```sh
export ANTHROPIC_API_KEY=...

bundle exec ruby examples/ports/paperclip/superpowers/team.rb \
  "<task for the team>"
```
