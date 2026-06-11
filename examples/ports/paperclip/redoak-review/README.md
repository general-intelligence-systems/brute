# RedOak Review

A boutique code quality, design, and security review agency powered by pragmatic, opinionated review workflows. A **team of 5 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`redoak-review`](https://github.com/paperclipai/companies/tree/main/redoak-review)). Authored upstream by Patrick Ellis.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo
├─► ci-integration-engineer  (code-review-action, design-review-action, security-review-action)
├─► code-reviewer  (pragmatic-code-review)
├─► design-reviewer  (design-review)
└─► security-reviewer  (security-review)
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

bundle exec ruby examples/ports/paperclip/redoak-review/team.rb \
  "<task for the team>"
```
