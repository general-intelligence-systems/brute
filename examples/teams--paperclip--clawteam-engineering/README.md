# ClawTeam Engineering

Agentic software engineering through self-organizing multi-agent teams that plan, build, review, test, and deploy software autonomously. A **team of 5 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`clawteam-engineering`](https://github.com/paperclipai/companies/tree/main/clawteam-engineering)).

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (clawteam)
├─► backend-developer  (clawteam)
├─► devops-engineer  (clawteam)
├─► frontend-developer  (clawteam)
└─► qa-engineer  (clawteam)
```

Upstream also assigns the `paperclip` skill — instructions for the Paperclip control-plane API, which has no counterpart here; it is intentionally not copied.

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

bundle exec ruby examples/ports/paperclip/clawteam-engineering/team.rb \
  "<task for the team>"
```
