# Aeon Intelligence

Autonomous AI intelligence company powered by Aeon — runs research, engineering, crypto monitoring, and productivity workflows on GitHub Actions via Claude Code. A **team of 4 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`aeon-intelligence`](https://github.com/paperclipai/companies/tree/main/aeon-intelligence)).

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (morning-brief, weekly-review, goal-tracker, digest, idea-capture, heartbeat, memory-flush, reflect, skill-health, self-review)
├─► crypto-analyst  (token-alert, wallet-digest, on-chain-monitor, defi-monitor)
├─► engineering-lead  (pr-review, github-monitor, issue-triage, changelog, code-health, feature, build-skill, search-skill)
└─► research-analyst  (article, research-brief, paper-digest, hacker-news-digest, rss-digest, reddit-digest, security-digest, tweet-digest, fetch-tweets, search-papers)
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

bundle exec ruby examples/ports/paperclip/aeon-intelligence/team.rb \
  "<task for the team>"
```
