# Product Compass Consulting

Full-service AI product management consultancy with 65 specialized skills covering discovery, strategy, execution, research, analytics, go-to-market, marketing, and PM career tools. A **team of 48 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`product-compass-consulting`](https://github.com/paperclipai/companies/tree/main/product-compass-consulting)). Authored upstream by Pawel Huryn.

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo
├─► director-data-analytics
│   ├─► experimentation-analyst  (ab-test-analysis, cohort-analysis)
│   └─► sql-analyst  (sql-queries)
├─► director-gtm
│   ├─► battlecard-writer  (competitive-battlecard)
│   ├─► growth-strategist  (growth-loops, gtm-motions)
│   └─► gtm-strategist  (gtm-strategy, beachhead-segment, ideal-customer-profile)
├─► director-market-research
│   ├─► competitive-analyst  (competitor-analysis)
│   ├─► journey-mapper  (customer-journey-map)
│   ├─► market-sizing-analyst  (market-sizing, market-segments)
│   ├─► persona-specialist  (user-personas, user-segmentation)
│   └─► sentiment-analyst  (sentiment-analysis)
├─► director-marketing
│   ├─► brand-specialist  (product-name)
│   ├─► marketing-strategist  (marketing-ideas, positioning-ideas, value-prop-statements)
│   └─► north-star-analyst  (north-star-metric)
├─► director-toolkit
│   ├─► career-specialist  (review-resume)
│   ├─► editor  (grammar-check)
│   └─► legal-specialist  (draft-nda, privacy-policy)
├─► vp-discovery
│   ├─► assumption-analyst  (identify-assumptions-existing, identify-assumptions-new, prioritize-assumptions)
│   ├─► experiment-designer  (brainstorm-experiments-existing, brainstorm-experiments-new)
│   ├─► feature-analyst  (analyze-feature-requests, prioritize-features)
│   ├─► ideation-specialist  (brainstorm-ideas-existing, brainstorm-ideas-new)
│   ├─► metrics-designer  (metrics-dashboard)
│   ├─► ost-analyst  (opportunity-solution-tree)
│   └─► user-researcher  (interview-script, summarize-interview)
├─► vp-execution
│   ├─► data-generator  (dummy-dataset)
│   ├─► meeting-analyst  (summarize-meeting)
│   ├─► okr-specialist  (brainstorm-okrs)
│   ├─► prd-writer  (create-prd)
│   ├─► prioritization-specialist  (prioritization-frameworks)
│   ├─► qa-specialist  (test-scenarios)
│   ├─► release-manager  (release-notes)
│   ├─► risk-analyst  (pre-mortem)
│   ├─► roadmap-specialist  (outcome-roadmap)
│   ├─► sprint-manager  (sprint-plan, retro)
│   ├─► stakeholder-analyst  (stakeholder-map)
│   └─► story-writer  (user-stories, job-stories, wwas)
└─► vp-strategy
    ├─► business-model-analyst  (lean-canvas, business-model, startup-canvas, value-proposition)
    ├─► competitive-intel-analyst  (swot-analysis, pestle-analysis, porters-five-forces, ansoff-matrix)
    ├─► pricing-strategist  (pricing-strategy, monetization-strategy)
    └─► vision-strategist  (product-strategy, product-vision)
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

bundle exec ruby examples/ports/paperclip/product-compass-consulting/team.rb \
  "<task for the team>"
```
