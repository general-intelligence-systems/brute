# MiniMax Studio

A full-service digital studio run as a **team of agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`minimax-studio`](https://github.com/paperclipai/companies/tree/main/minimax-studio),
itself generated from [MiniMax-AI/skills](https://github.com/MiniMax-AI/skills)).

The company definition is verbatim upstream markdown — `COMPANY.md`, the five
`agents/*/AGENTS.md` role definitions, and all ten skills. `team.rb` only does
the wiring: the CEO is a `Brute::Agent` whose tools are the four specialists,
each a `Brute::Tools::SubAgent` with its role prompt and its own skills.

```
ceo ──► app-engineer       (frontend-dev, fullstack-dev)
    ──► mobile-engineer    (android-native-dev, ios-application-dev)
    ──► graphics-engineer  (shader-dev, gif-sticker-maker)
    ──► document-producer  (minimax-pdf, minimax-docx, minimax-xlsx, pptx-generator)
```

## Layout

| Path | Role |
|------|------|
| `team.rb` | wiring (run this) |
| `COMPANY.md` | upstream company manifest, verbatim |
| `agents/<name>/AGENTS.md` | upstream role definitions, verbatim |
| `agents/<name>/.brute/skills/` | each specialist's skills, verbatim |

## Usage

```sh
export ANTHROPIC_API_KEY=...
export MINIMAX_API_KEY=...   # optional — used by some skills

bundle exec ruby examples/ports/paperclip/minimax-studio/team.rb \
  "Build me a landing page for a coffee subscription service"
```
