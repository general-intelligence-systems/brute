# TÂCHES Creative

A creative strategy and meta-skills agency specializing in thinking frameworks, research methodology, and AI workflow optimization. A **team of 6 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`taches-creative`](https://github.com/paperclipai/companies/tree/main/taches-creative)). Authored upstream by TÂCHES, glittercowboy.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (create-plans, create-meta-prompts, context-handoff, todo-management, meta-prompting)
├─► quality-auditor  (create-agent-skills, create-slash-commands, create-subagents)
├─► research-lead  (research-competitive, research-deep-dive, research-feasibility, research-history, research-landscape, research-open-source, research-options, research-technical)
├─► skills-architect  (create-agent-skills, create-subagents, create-mcp-servers, debug-like-expert, setup-ralph, iphone-apps-expertise, macos-apps-expertise, n8n-automations-expertise)
├─► strategy-director  (consider-pareto, consider-first-principles, consider-inversion, consider-second-order, consider-5-whys, consider-occams-razor, consider-one-thing, consider-swot, consider-eisenhower-matrix, consider-10-10-10, consider-opportunity-cost, consider-via-negativa)
└─► workflow-designer  (create-slash-commands, create-hooks, todo-management, context-handoff)
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

bundle exec ruby examples/ports/paperclip/taches-creative/team.rb \
  "<task for the team>"
```
