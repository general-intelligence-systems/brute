# AgentSys Engineering

AI-powered software engineering company that orchestrates the full development lifecycle — from task discovery through production shipping. A **team of 5 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`agentsys-engineering`](https://github.com/paperclipai/companies/tree/main/agentsys-engineering)). Authored upstream by Dotta.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (discover-tasks, orchestrate-review)
├─► cto  (drift-analysis, repo-intel, enhance-orchestrator)
│   ├─► research-perf-analyst  (perf-analyzer, perf-benchmarker, learn, consult, debate)
│   └─► staff-engineer  (deslop, validate-delivery, enhance-prompts)
└─► qa-release-lead  (orchestrate-review, validate-delivery, sync-docs)
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

bundle exec ruby examples/ports/paperclip/agentsys-engineering/team.rb \
  "<task for the team>"
```
