# Agency Agents

A complete AI agency with 167 specialized agents across 10 divisions — engineering, design, marketing, product, sales, QA, operations, game development, spatial computing, and specialized operations. A **team of 167 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`agency-agents`](https://github.com/paperclipai/companies/tree/main/agency-agents)). Authored upstream by AgentLand Contributors.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo
├─► chief-of-staff
│   ├─► academic-anthropologist
│   ├─► academic-geographer
│   ├─► academic-historian
│   ├─► academic-narratologist
│   ├─► academic-psychologist
│   ├─► accounts-payable-agent
│   ├─► agentic-identity-trust
│   ├─► agents-orchestrator
│   ├─► automation-governance-architect
│   ├─► blockchain-security-auditor
│   ├─► compliance-auditor
│   ├─► corporate-training-designer
│   ├─► data-consolidation-agent
│   ├─► government-digital-presales-consultant
│   ├─► healthcare-marketing-compliance
│   ├─► identity-graph-operator
│   ├─► lsp-index-engineer
│   ├─► recruitment-specialist
│   ├─► report-distribution-agent
│   ├─► sales-data-extraction-agent
│   ├─► specialized-cultural-intelligence-strategist
│   ├─► specialized-developer-advocate
│   ├─► specialized-document-generator
│   ├─► specialized-french-consulting-market
│   ├─► specialized-korean-business-navigator
│   ├─► specialized-mcp-builder
│   ├─► specialized-model-qa
│   ├─► specialized-salesforce-architect
│   ├─► specialized-workflow-architect
│   ├─► study-abroad-advisor
│   ├─► supply-chain-strategist
│   └─► zk-steward
├─► cmo
│   ├─► marketing-ai-citation-strategist
│   ├─► marketing-app-store-optimizer
│   ├─► marketing-baidu-seo-specialist
│   ├─► marketing-bilibili-content-strategist
│   ├─► marketing-book-co-author
│   ├─► marketing-carousel-growth-engine
│   ├─► marketing-china-ecommerce-operator
│   ├─► marketing-content-creator
│   ├─► marketing-cross-border-ecommerce
│   ├─► marketing-douyin-strategist
│   ├─► marketing-growth-hacker
│   ├─► marketing-instagram-curator
│   ├─► marketing-kuaishou-strategist
│   ├─► marketing-linkedin-content-creator
│   ├─► marketing-livestream-commerce-coach
│   ├─► marketing-podcast-strategist
│   ├─► marketing-private-domain-operator
│   ├─► marketing-reddit-community-builder
│   ├─► marketing-seo-specialist
│   ├─► marketing-short-video-editing-coach
│   ├─► marketing-social-media-strategist
│   ├─► marketing-tiktok-strategist
│   ├─► marketing-twitter-engager
│   ├─► marketing-wechat-official-account
│   ├─► marketing-weibo-strategist
│   ├─► marketing-xiaohongshu-specialist
│   ├─► marketing-zhihu-strategist
│   ├─► paid-media-auditor
│   ├─► paid-media-creative-strategist
│   ├─► paid-media-paid-social-strategist
│   ├─► paid-media-ppc-strategist
│   ├─► paid-media-programmatic-buyer
│   ├─► paid-media-search-query-analyst
│   └─► paid-media-tracking-specialist
├─► creative-director
│   ├─► design-brand-guardian
│   ├─► design-image-prompt-engineer
│   ├─► design-inclusive-visuals-specialist
│   ├─► design-ui-designer
│   ├─► design-ux-architect
│   ├─► design-ux-researcher
│   ├─► design-visual-storyteller
│   └─► design-whimsy-injector
├─► game-dev-director
│   ├─► blender-addon-engineer
│   ├─► game-audio-engineer
│   ├─► game-designer
│   ├─► godot-gameplay-scripter
│   ├─► godot-multiplayer-engineer
│   ├─► godot-shader-developer
│   ├─► level-designer
│   ├─► narrative-designer
│   ├─► roblox-avatar-creator
│   ├─► roblox-experience-designer
│   ├─► roblox-systems-scripter
│   ├─► technical-artist
│   ├─► unity-architect
│   ├─► unity-editor-tool-developer
│   ├─► unity-multiplayer-engineer
│   ├─► unity-shader-graph-artist
│   ├─► unreal-multiplayer-architect
│   ├─► unreal-systems-engineer
│   ├─► unreal-technical-artist
│   └─► unreal-world-builder
├─► vp-engineering
│   ├─► engineering-ai-data-remediation-engineer
│   ├─► engineering-ai-engineer
│   ├─► engineering-autonomous-optimization-architect
│   ├─► engineering-backend-architect
│   ├─► engineering-code-reviewer
│   ├─► engineering-data-engineer
│   ├─► engineering-database-optimizer
│   ├─► engineering-devops-automator
│   ├─► engineering-embedded-firmware-engineer
│   ├─► engineering-feishu-integration-developer
│   ├─► engineering-frontend-developer
│   ├─► engineering-git-workflow-master
│   ├─► engineering-incident-response-commander
│   ├─► engineering-mobile-app-builder
│   ├─► engineering-rapid-prototyper
│   ├─► engineering-security-engineer
│   ├─► engineering-senior-developer
│   ├─► engineering-software-architect
│   ├─► engineering-solidity-smart-contract-engineer
│   ├─► engineering-sre
│   ├─► engineering-technical-writer
│   ├─► engineering-threat-detection-engineer
│   ├─► engineering-wechat-mini-program-developer
│   ├─► qa-director
│   │   ├─► testing-accessibility-auditor
│   │   ├─► testing-api-tester
│   │   ├─► testing-evidence-collector
│   │   ├─► testing-performance-benchmarker
│   │   ├─► testing-reality-checker
│   │   ├─► testing-test-results-analyzer
│   │   ├─► testing-tool-evaluator
│   │   └─► testing-workflow-optimizer
│   └─► xr-director
│       ├─► macos-spatial-metal-engineer
│       ├─► terminal-integration-specialist
│       ├─► visionos-spatial-engineer
│       ├─► xr-cockpit-interaction-specialist
│       ├─► xr-immersive-developer
│       └─► xr-interface-architect
├─► vp-operations
│   ├─► support-analytics-reporter
│   ├─► support-executive-summary-generator
│   ├─► support-finance-tracker
│   ├─► support-infrastructure-maintainer
│   ├─► support-legal-compliance-checker
│   └─► support-support-responder
├─► vp-product
│   ├─► product-behavioral-nudge-engine
│   ├─► product-feedback-synthesizer
│   ├─► product-manager
│   ├─► product-sprint-prioritizer
│   ├─► product-trend-researcher
│   ├─► project-management-experiment-tracker
│   ├─► project-management-jira-workflow-steward
│   ├─► project-management-project-shepherd
│   ├─► project-management-studio-operations
│   ├─► project-management-studio-producer
│   └─► project-manager-senior
└─► vp-sales
    ├─► sales-account-strategist
    ├─► sales-coach
    ├─► sales-deal-strategist
    ├─► sales-discovery-coach
    ├─► sales-engineer
    ├─► sales-outbound-strategist
    ├─► sales-pipeline-analyst
    └─► sales-proposal-strategist
```

## Layout

| Path | Role |
|------|------|
| `team.rb` | wiring (run this) |
| `COMPANY.md` | upstream company manifest, verbatim |
| `agents/<name>/AGENTS.md` | upstream role definitions, verbatim |

## Usage

```sh
export ANTHROPIC_API_KEY=...

bundle exec ruby examples/ports/paperclip/agency-agents/team.rb \
  "<task for the team>"
```
