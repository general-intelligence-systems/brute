#!/usr/bin/env ruby
# frozen_string_literal: true

# Product Compass Consulting — a team of agents, ported from paperclipai/companies
# (companies/product-compass-consulting).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo
#   ├─► director-data-analytics
#   │   ├─► experimentation-analyst  (ab-test-analysis, cohort-analysis)
#   │   └─► sql-analyst  (sql-queries)
#   ├─► director-gtm
#   │   ├─► battlecard-writer  (competitive-battlecard)
#   │   ├─► growth-strategist  (growth-loops, gtm-motions)
#   │   └─► gtm-strategist  (gtm-strategy, beachhead-segment, ideal-customer-profile)
#   ├─► director-market-research
#   │   ├─► competitive-analyst  (competitor-analysis)
#   │   ├─► journey-mapper  (customer-journey-map)
#   │   ├─► market-sizing-analyst  (market-sizing, market-segments)
#   │   ├─► persona-specialist  (user-personas, user-segmentation)
#   │   └─► sentiment-analyst  (sentiment-analysis)
#   ├─► director-marketing
#   │   ├─► brand-specialist  (product-name)
#   │   ├─► marketing-strategist  (marketing-ideas, positioning-ideas, value-prop-statements)
#   │   └─► north-star-analyst  (north-star-metric)
#   ├─► director-toolkit
#   │   ├─► career-specialist  (review-resume)
#   │   ├─► editor  (grammar-check)
#   │   └─► legal-specialist  (draft-nda, privacy-policy)
#   ├─► vp-discovery
#   │   ├─► assumption-analyst  (identify-assumptions-existing, identify-assumptions-new, prioritize-assumptions)
#   │   ├─► experiment-designer  (brainstorm-experiments-existing, brainstorm-experiments-new)
#   │   ├─► feature-analyst  (analyze-feature-requests, prioritize-features)
#   │   ├─► ideation-specialist  (brainstorm-ideas-existing, brainstorm-ideas-new)
#   │   ├─► metrics-designer  (metrics-dashboard)
#   │   ├─► ost-analyst  (opportunity-solution-tree)
#   │   └─► user-researcher  (interview-script, summarize-interview)
#   ├─► vp-execution
#   │   ├─► data-generator  (dummy-dataset)
#   │   ├─► meeting-analyst  (summarize-meeting)
#   │   ├─► okr-specialist  (brainstorm-okrs)
#   │   ├─► prd-writer  (create-prd)
#   │   ├─► prioritization-specialist  (prioritization-frameworks)
#   │   ├─► qa-specialist  (test-scenarios)
#   │   ├─► release-manager  (release-notes)
#   │   ├─► risk-analyst  (pre-mortem)
#   │   ├─► roadmap-specialist  (outcome-roadmap)
#   │   ├─► sprint-manager  (sprint-plan, retro)
#   │   ├─► stakeholder-analyst  (stakeholder-map)
#   │   └─► story-writer  (user-stories, job-stories, wwas)
#   └─► vp-strategy
#       ├─► business-model-analyst  (lean-canvas, business-model, startup-canvas, value-proposition)
#       ├─► competitive-intel-analyst  (swot-analysis, pestle-analysis, porters-five-forces, ansoff-matrix)
#       ├─► pricing-strategist  (pricing-strategy, monetization-strategy)
#       └─► vision-strategist  (product-strategy, product-vision)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/product-compass-consulting/team.rb \
#     "<task for the team>"

require "bundler/setup"
require "brute"

MODEL = "claude-sonnet-4-20250514"

# Strip YAML frontmatter from an upstream markdown file, returning
# [frontmatter_hash, body].
def load_agent_md(path)
  raw = File.read(path)
  parts = raw.split(/^---\s*$/, 3)
  [YAML.safe_load(parts[1]), parts[2].strip]
end

def agent_dir(name) = File.join(__dir__, "agents", name)

# Build one team member as a SubAgent: verbatim AGENTS.md body as its
# system prompt, its own skills dir, the working tools, and its direct
# reports (if any) as callable sub-agents.
def member(name, description, reports: [])
  _meta, body = load_agent_md(File.join(agent_dir(name), "AGENTS.md"))

  prompt = Brute::SystemPrompt.build do |p, ctx|
    p << body
    skills = Brute::Prompts::Skills.call(ctx.merge(cwd: agent_dir(name)))
    p << skills if skills
    unless reports.empty?
      p << "Your direct reports are available as tools — call one to " \
           "delegate, passing the full task context."
    end
  end

  Brute::Tools::SubAgent.new(
    name:        name,
    description: description,
    provider:    Brute.provider,
    model:       MODEL,
    tools:       Brute::Tools::ALL + reports,
  ) do
    use Brute::Middleware::EventHandler,
        handler_class: Brute::Events::PrefixedTerminalOutput, prefix: name
    use Brute::Middleware::SystemPrompt, system_prompt: prompt
    use Brute::Middleware::ToolResultLoop
    use Brute::Middleware::MaxIterations
    use Brute::Middleware::ToolCall
    run Brute::Middleware::Completion::RubyLLM.new
  end
end

# The org chart, leaves first, so each manager can reference its reports.
# Descriptions come from each agent's "Where work comes from" /
# "What triggers you" section (or its opening paragraph).
experimentation_analyst = member("experimentation-analyst",
           "Experimentation Analyst — You receive experiment results from the " \
           "Experiment Designer on the Discovery team, or cohort analysis requests " \
           "from any team.")

sql_analyst = member("sql-analyst",
           "SQL Analyst — You receive query requests from the Director of Data " \
           "Analytics or directly from teams that need data.")

director_data_analytics = member("director-data-analytics",
           "Director of Data Analytics — You receive analysis requests from the CPO " \
           "or other teams that need data work.",
           reports: [experimentation_analyst, sql_analyst])

battlecard_writer = member("battlecard-writer",
           "Battlecard Writer — You receive competitive intelligence from the " \
           "Competitive Analyst on the Market Research team, or direct requests from " \
           "the Director of Go-to-Market.")

growth_strategist = member("growth-strategist",
           "Growth Strategist — You receive growth strategy requests from the " \
           "Director of Go-to-Market or the GTM Strategist.")

gtm_strategist = member("gtm-strategist",
           "GTM Strategist — You receive launch briefs from the Director of " \
           "Go-to-Market or strategy outputs from the Product Strategy team.")

director_gtm = member("director-gtm",
           "Director of Go-to-Market — You receive launch briefs from the CPO or " \
           "strategy handoffs from the VP of Product Strategy.",
           reports: [battlecard_writer, growth_strategist, gtm_strategist])

competitive_analyst = member("competitive-analyst",
           "Competitive Analyst — You receive competitive analysis requests from the " \
           "Director of Market Research or the Product Strategy team.")

journey_mapper = member("journey-mapper",
           "Journey Mapper — You receive mapping requests from the Director of " \
           "Market Research, often building on personas from the Persona Specialist.")

market_sizing_analyst = member("market-sizing-analyst",
           "Market Sizing Analyst — You receive market analysis requests from the " \
           "Director of Market Research or the Product Strategy team.")

persona_specialist = member("persona-specialist",
           "Persona Specialist — You receive research data or user feedback from the " \
           "Director of Market Research, or interview findings from the User " \
           "Researcher.")

sentiment_analyst = member("sentiment-analyst",
           "Sentiment Analyst — You receive user feedback datasets from the Director " \
           "of Market Research — reviews, surveys, support tickets, NPS responses.")

director_market_research = member("director-market-research",
           "Director of Market Research — You receive research briefs from the CPO " \
           "or requests from other teams that need market or customer data.",
           reports: [competitive_analyst, journey_mapper, market_sizing_analyst, persona_specialist, sentiment_analyst])

brand_specialist = member("brand-specialist",
           "Brand Specialist — You receive naming requests from the Director of " \
           "Marketing or the Vision Strategist when a new product or feature needs a " \
           "name.")

marketing_strategist = member("marketing-strategist",
           "Marketing Strategist — You receive marketing briefs from the Director of " \
           "Marketing or positioning needs from the Go-to-Market team.")

north_star_analyst = member("north-star-analyst",
           "North Star Analyst — You receive metrics framework requests from the " \
           "Director of Marketing or the CPO.")

director_marketing = member("director-marketing",
           "Director of Marketing & Growth — You receive marketing briefs from the " \
           "CPO or handoffs from the Go-to-Market team after launch strategy is set.",
           reports: [brand_specialist, marketing_strategist, north_star_analyst])

career_specialist = member("career-specialist",
           "Career Specialist — You receive resume review requests from the Director " \
           "of PM Toolkit or directly from users.")

editor = member("editor",
           "Editor — You receive proofreading requests from any team — release notes " \
           "from the Release Manager, marketing copy from the Marketing Strategist, " \
           "legal documents from the Legal Specialist, or any content that needs " \
           "polishing.")

legal_specialist = member("legal-specialist",
           "Legal Document Specialist — You receive legal document requests from the " \
           "Director of PM Toolkit or directly from users.")

director_toolkit = member("director-toolkit",
           "Director of PM Toolkit — You receive utility requests from the CPO or " \
           "directly from users for career, legal, or editing support.",
           reports: [career_specialist, editor, legal_specialist])

assumption_analyst = member("assumption-analyst",
           "Assumption Analyst — You receive feature ideas or product concepts from " \
           "the VP of Product Discovery or the Ideation Specialist that need " \
           "assumption mapping.")

experiment_designer = member("experiment-designer",
           "Experiment Designer — You receive prioritized assumptions from the " \
           "Assumption Analyst or product concepts from the VP of Product Discovery.")

feature_analyst = member("feature-analyst",
           "Feature Analyst — You receive feature request lists, backlog items, or " \
           "prioritization challenges from the VP of Product Discovery.")

ideation_specialist = member("ideation-specialist",
           "Ideation Specialist — You receive ideation requests from the VP of " \
           "Product Discovery, typically when a client needs fresh ideas for a new " \
           "or existing product.")

metrics_designer = member("metrics-designer",
           "Metrics Designer — You receive dashboard design requests from the VP of " \
           "Product Discovery or other teams that need to measure product outcomes.")

ost_analyst = member("ost-analyst",
           "Opportunity Solution Tree Analyst — You receive requests from the VP of " \
           "Product Discovery when a team needs to structure their discovery work " \
           "around a desired outcome.")

user_researcher = member("user-researcher",
           "User Researcher — You receive research briefs from the VP of Product " \
           "Discovery when the team needs direct customer insight.")

vp_discovery = member("vp-discovery",
           "Vice President of Product Discovery — You receive discovery briefs from " \
           "the CPO or directly from users who need help with ideation, assumption " \
           "testing, or user research.",
           reports: [assumption_analyst, experiment_designer, feature_analyst, ideation_specialist, metrics_designer, ost_analyst, user_researcher])

data_generator = member("data-generator",
           "Data Generator — You receive dataset requests from the VP of Product " \
           "Execution, the Data Analytics team, or any team that needs test data.")

meeting_analyst = member("meeting-analyst",
           "Meeting Analyst — You receive meeting recordings or transcripts from " \
           "anyone in the organization who needs meeting notes.")

okr_specialist = member("okr-specialist",
           "OKR Specialist — You receive OKR requests from the VP of Product " \
           "Execution, typically at the start of a planning cycle.")

prd_writer = member("prd-writer",
           "PRD Writer — You receive feature briefs from the VP of Product Execution " \
           "or strategy outputs from the Product Strategy team.")

prioritization_specialist = member("prioritization-specialist",
           "Prioritization Specialist — You receive prioritization requests from the " \
           "VP of Product Execution or from teams struggling to decide what to build " \
           "next.")

qa_specialist = member("qa-specialist",
           "QA Specialist — You receive user stories from the Story Writer or " \
           "feature specs from the PRD Writer.")

release_manager = member("release-manager",
           "Release Manager — You receive shipped work summaries from the Sprint " \
           "Manager or ticket/PRD references from the VP of Product Execution.")

risk_analyst = member("risk-analyst",
           "Risk Analyst — You receive PRDs or launch plans from the PRD Writer or " \
           "VP of Product Execution that need risk assessment.")

roadmap_specialist = member("roadmap-specialist",
           "Roadmap Specialist — You receive roadmap requests from the VP of Product " \
           "Execution or existing feature roadmaps that need strategic reframing.")

sprint_manager = member("sprint-manager",
           "Sprint Manager — You receive sprint planning requests from the VP of " \
           "Product Execution and stories/tasks from the Story Writer.")

stakeholder_analyst = member("stakeholder-analyst",
           "Stakeholder Analyst — You receive stakeholder mapping requests from the " \
           "VP of Product Execution, typically before major launches or " \
           "cross-functional initiatives.")

story_writer = member("story-writer",
           "Story Writer — You receive PRDs from the PRD Writer or feature briefs " \
           "from the VP of Product Execution.")

vp_execution = member("vp-execution",
           "Vice President of Product Execution — You receive execution briefs from " \
           "the CPO, strategy handoffs from the VP of Product Strategy, or direct " \
           "user requests for execution artifacts.",
           reports: [data_generator, meeting_analyst, okr_specialist, prd_writer, prioritization_specialist, qa_specialist, release_manager, risk_analyst, roadmap_specialist, sprint_manager, stakeholder_analyst, story_writer])

business_model_analyst = member("business-model-analyst",
           "Business Model Analyst — You receive business model requests from the VP " \
           "of Product Strategy or the Vision Strategist when a product needs " \
           "business model validation.")

competitive_intel_analyst = member("competitive-intel-analyst",
           "Competitive Intelligence Analyst — You receive analysis requests from " \
           "the VP of Product Strategy when a client needs to understand their " \
           "competitive position or market dynamics.")

pricing_strategist = member("pricing-strategist",
           "Pricing Strategist — You receive pricing requests from the VP of Product " \
           "Strategy or the Business Model Analyst when a product needs pricing " \
           "design.")

vision_strategist = member("vision-strategist",
           "Vision Strategist — You receive strategy requests from the VP of Product " \
           "Strategy when a client needs a product strategy or vision.")

vp_strategy = member("vp-strategy",
           "Vice President of Product Strategy — You receive strategy briefs from " \
           "the CPO or directly from users who need strategic framing for their " \
           "product.",
           reports: [business_model_analyst, competitive_intel_analyst, pricing_strategist, vision_strategist])

TEAM = [director_data_analytics, director_gtm, director_market_research, director_marketing, director_toolkit, vp_discovery, vp_execution, vp_strategy].freeze

# The Chief Product Officer & CEO's prompt is the company description (COMPANY.md body)
# plus its own AGENTS.md, both verbatim.
_company_meta, company_body = load_agent_md(File.join(__dir__, "COMPANY.md"))
_root_meta, root_body       = load_agent_md(File.join(agent_dir("ceo"), "AGENTS.md"))

ROOT_PROMPT = Brute::SystemPrompt.build do |p, ctx|
  p << company_body
  p << root_body
  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: agent_dir("ceo")))
  p << skills if skills
  p << "Your direct reports are available as tools — call one to delegate, " \
       "passing the full task context. Synthesize their results before " \
       "replying to the user."
end

root = Brute::Agent.new(
  provider: Brute.provider,
  model:    MODEL,
  tools:    TEAM,
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: ROOT_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

request = ARGV.join(" ")
request = "Introduce the team: who's on it and what can each member do?" if request.empty?

session = Brute::Session.new
session.user(request)
root.call(session)
