# ClawTeam Research Lab

Autonomous AI research automation through coordinated multi-agent teams that conduct literature surveys, design experiments, run analyses, and synthesize findings. A **team of 4 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`clawteam-research-lab`](https://github.com/paperclipai/companies/tree/main/clawteam-research-lab)).

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (clawteam)
├─► data-analyst  (clawteam)
├─► literature-surveyor  (clawteam)
└─► methodology-designer  (clawteam)
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

bundle exec ruby examples/ports/paperclip/clawteam-research-lab/team.rb \
  "<task for the team>"
```
