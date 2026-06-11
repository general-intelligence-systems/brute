# GStack

Engineering company powered by gstack workflow skills — distinct cognitive modes for product vision, design critique, technical planning, security auditing, code review, shipping, deployment, and QA. A **team of 5 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`gstack`](https://github.com/paperclipai/companies/tree/main/gstack)). Authored upstream by Dotta, Garry Tan.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (plan-ceo-review, office-hours, autoplan)
└─► cto  (plan-eng-review, plan-design-review, retro, cso, codex)
    ├─► qa-engineer  (browse, qa, qa-only, benchmark, canary, design-review, design-consultation, setup-browser-cookies)
    ├─► release-engineer  (ship, land-and-deploy, document-release, setup-deploy)
    └─► staff-engineer  (review, investigate)
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

bundle exec ruby examples/ports/paperclip/gstack/team.rb \
  "<task for the team>"
```
