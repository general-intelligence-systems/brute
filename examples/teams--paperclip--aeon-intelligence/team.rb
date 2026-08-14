#!/usr/bin/env ruby
# frozen_string_literal: true

# Aeon Intelligence — a team of agents, ported from paperclipai/companies
# (companies/aeon-intelligence).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo  (morning-brief, weekly-review, goal-tracker, digest, idea-capture, heartbeat, memory-flush, reflect, skill-health, self-review)
#   ├─► crypto-analyst  (token-alert, wallet-digest, on-chain-monitor, defi-monitor)
#   ├─► engineering-lead  (pr-review, github-monitor, issue-triage, changelog, code-health, feature, build-skill, search-skill)
#   └─► research-analyst  (article, research-brief, paper-digest, hacker-news-digest, rss-digest, reddit-digest, security-digest, tweet-digest, fetch-tweets, search-papers)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/aeon-intelligence/team.rb \
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
crypto_analyst = member("crypto-analyst",
           "On-Chain Intelligence — Scheduled runs: Your skills fire on cron " \
           "schedules to scan on-chain data, check token prices, monitor wallet " \
           "activity, and track DeFi protocol changes.; CIO requests: The CIO may " \
           "ask for a wallet deep-dive, token analysis, or DeFi risk assessment.; " \
           "User messages: Direct crypto questions routed to…")

engineering_lead = member("engineering-lead",
           "Dev & Code Lead — Scheduled runs: github-monitor and code-health fire on " \
           "cron to scan watched repos for new activity, stale PRs, and health " \
           "metrics.; Event-driven: pr-review triggers when new PRs appear on " \
           "watched repos. issue-triage triggers when new issues are filed.; CIO " \
           "requests: The CIO may assign feature work,…")

research_analyst = member("research-analyst",
           "Research & Content Lead — Scheduled runs: Your skills fire on cron " \
           "schedules. Each digest skill scans its sources, filters for relevance, " \
           "and produces a summary committed to the repo.; CIO requests: The Chief " \
           "Intelligence Officer may ask you to research a specific topic, produce " \
           "an article, or deep-dive into a paper.; User…")

TEAM = [crypto_analyst, engineering_lead, research_analyst].freeze

# The Chief Intelligence Officer & CEO's prompt is the company description (COMPANY.md body)
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
