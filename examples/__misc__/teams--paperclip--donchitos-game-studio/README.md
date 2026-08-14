# Donchitos Game Studio

Full-service indie game development studio with 49 coordinated AI agents spanning creative direction, engineering, design, art, audio, narrative, QA, and production. A **team of 49 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`donchitos-game-studio`](https://github.com/paperclipai/companies/tree/main/donchitos-game-studio)). Authored upstream by Donchitos.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (milestone-review, scope-check)
├─► creative-director  (brainstorm, design-review)
│   ├─► art-director
│   │   ├─► technical-artist
│   │   └─► ux-designer
│   ├─► audio-director
│   │   └─► sound-designer
│   ├─► game-designer  (design-review, balance-check, brainstorm)
│   │   ├─► economy-designer
│   │   ├─► level-designer
│   │   └─► systems-designer
│   └─► narrative-director
│       ├─► world-builder
│       └─► writer
├─► producer  (sprint-plan, scope-check, estimate, milestone-review)
│   ├─► accessibility-specialist
│   ├─► analytics-engineer
│   ├─► community-manager
│   ├─► devops-engineer
│   ├─► live-ops-designer
│   ├─► localization-lead
│   ├─► prototyper
│   ├─► release-manager  (release-checklist, changelog, patch-notes)
│   └─► security-engineer
└─► technical-director
    ├─► lead-programmer  (code-review, architecture-decision, tech-debt)
    │   ├─► ai-programmer
    │   ├─► engine-programmer
    │   ├─► gameplay-programmer
    │   ├─► godot-specialist
    │   │   ├─► godot-gdextension-specialist
    │   │   ├─► godot-gdscript-specialist
    │   │   └─► godot-shader-specialist
    │   ├─► network-programmer
    │   ├─► tools-programmer
    │   ├─► ui-programmer
    │   ├─► unity-specialist
    │   │   ├─► unity-addressables-specialist
    │   │   ├─► unity-dots-specialist
    │   │   ├─► unity-shader-specialist
    │   │   └─► unity-ui-specialist
    │   └─► unreal-specialist
    │       ├─► ue-blueprint-specialist
    │       ├─► ue-gas-specialist
    │       ├─► ue-replication-specialist
    │       └─► ue-umg-specialist
    ├─► performance-analyst
    └─► qa-lead  (bug-report, release-checklist)
        └─► qa-tester
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

bundle exec ruby examples/ports/paperclip/donchitos-game-studio/team.rb \
  "<task for the team>"
```
