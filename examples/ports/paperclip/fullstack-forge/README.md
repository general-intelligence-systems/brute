# Fullstack Forge

A full-service software development consultancy with 66 specialized skills covering 12 programming languages, 7 backend frameworks, frontend/mobile, infrastructure, security, data science, and DevOps. A **team of 49 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`fullstack-forge`](https://github.com/paperclipai/companies/tree/main/fullstack-forge)). Authored upstream by Jeffallan.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (feature-forge, spec-miner)
└─► cto  (architecture-designer, code-reviewer)
    ├─► architecture-lead  (the-fool)
    │   ├─► api-engineer  (api-designer, graphql-architect)
    │   ├─► distributed-systems-engineer  (microservices-architect, websocket-engineer)
    │   └─► mcp-engineer  (mcp-developer)
    ├─► backend-lead  (the-fool)
    │   ├─► enterprise-backend-engineer  (spring-boot-engineer, dotnet-core-expert)
    │   ├─► node-backend-engineer  (nestjs-expert)
    │   ├─► php-backend-engineer  (laravel-specialist)
    │   ├─► python-backend-engineer  (django-expert, fastapi-expert)
    │   └─► ruby-backend-engineer  (rails-expert)
    ├─► data-lead  (the-fool)
    │   ├─► ai-engineer  (prompt-engineer, rag-architect)
    │   ├─► data-engineer  (pandas-pro, spark-engineer)
    │   └─► ml-engineer  (ml-pipeline, fine-tuning-expert)
    ├─► devops-lead  (debugging-wizard)
    │   ├─► devops-engineer  (devops-engineer, cli-developer)
    │   └─► sre-engineer  (sre-engineer, monitoring-expert, chaos-engineer)
    ├─► embedded-systems-engineer  (embedded-systems)
    ├─► frontend-lead  (debugging-wizard)
    │   ├─► angular-engineer  (angular-architect)
    │   ├─► mobile-engineer  (react-native-expert, flutter-expert)
    │   ├─► react-engineer  (react-expert, nextjs-developer)
    │   └─► vue-engineer  (vue-expert, vue-expert-js)
    ├─► game-developer  (game-developer)
    ├─► infrastructure-lead  (the-fool)
    │   ├─► cloud-engineer  (cloud-architect, terraform-engineer)
    │   ├─► database-engineer  (postgres-pro, database-optimizer, sql-pro)
    │   └─► kubernetes-engineer  (kubernetes-specialist)
    ├─► language-engineering-lead  (debugging-wizard)
    │   ├─► go-engineer  (golang-pro)
    │   ├─► jvm-engineer  (java-architect, kotlin-specialist)
    │   ├─► mobile-language-engineer  (swift-expert)
    │   ├─► python-engineer  (python-pro)
    │   ├─► rust-engineer  (rust-engineer)
    │   ├─► systems-language-engineer  (cpp-pro, csharp-developer)
    │   ├─► typescript-engineer  (typescript-pro, javascript-pro)
    │   └─► web-language-engineer  (php-pro)
    ├─► legacy-modernization-specialist  (legacy-modernizer)
    ├─► platform-lead  (debugging-wizard)
    │   ├─► atlassian-engineer  (atlassian-mcp)
    │   ├─► ecommerce-engineer  (shopify-expert, wordpress-pro)
    │   └─► salesforce-developer  (salesforce-developer)
    ├─► qa-lead  (debugging-wizard)
    │   ├─► code-quality-specialist  (code-reviewer, code-documenter)
    │   └─► test-engineer  (test-master, playwright-expert)
    └─► security-lead  (debugging-wizard)
        └─► security-engineer  (secure-code-guardian, security-reviewer, fullstack-guardian)
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

bundle exec ruby examples/ports/paperclip/fullstack-forge/team.rb \
  "<task for the team>"
```
