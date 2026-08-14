# Trail of Bits Security

A prestigious security auditing and verification firm with expertise in smart contract security, cryptographic analysis, binary reverse engineering, and application security testing. A **team of 28 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`trail-of-bits-security`](https://github.com/paperclipai/companies/tree/main/trail-of-bits-security)). Authored upstream by Trail of Bits, Dotta.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo
├─► chaos-agent  (let-fate-decide)
├─► chief-security-officer
│   ├─► audit-lead
│   │   ├─► burpsuite-analyst  (burpsuite-project-parser)
│   │   ├─► code-auditor  (agentic-actions-auditor, audit-context-building, sharp-edges, insecure-defaults, differential-review)
│   │   ├─► false-positive-analyst  (fp-check)
│   │   ├─► static-analysis-engineer  (static-analysis)
│   │   ├─► supply-chain-auditor  (supply-chain-risk-auditor)
│   │   ├─► testing-specialist  (testing-handbook-skills)
│   │   └─► variant-analyst  (variant-analysis, semgrep-rule-creator, semgrep-rule-variant-creator)
│   ├─► blockchain-security-lead
│   │   ├─► contract-entry-point-analyst  (entry-point-analyzer)
│   │   └─► smart-contract-auditor  (building-secure-contracts)
│   ├─► engineering-lead
│   │   ├─► infrastructure-engineer  (debug-buttercup, claude-in-chrome-troubleshooting)
│   │   ├─► skill-developer  (skill-improver, workflow-skill-design, ask-questions-if-underspecified, second-opinion)
│   │   └─► tooling-engineer  (gh-cli, git-cleanup, modern-python, devcontainer-setup, seatbelt-sandboxer)
│   ├─► reverse-engineering-lead
│   │   ├─► binary-analyst  (dwarf-expert)
│   │   ├─► malware-analyst  (yara-authoring)
│   │   └─► mobile-security-analyst  (firebase-apk-scanner)
│   └─► verification-lead
│       ├─► constant-time-analyst  (constant-time-analysis)
│       ├─► property-tester  (property-based-testing)
│       ├─► spec-compliance-analyst  (spec-to-code-compliance)
│       └─► zeroize-auditor  (zeroize-audit)
└─► culture-analyst  (culture-index)
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

bundle exec ruby examples/ports/paperclip/trail-of-bits-security/team.rb \
  "<task for the team>"
```
