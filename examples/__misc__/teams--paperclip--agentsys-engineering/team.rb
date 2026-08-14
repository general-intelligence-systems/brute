#!/usr/bin/env ruby
# frozen_string_literal: true

# AgentSys Engineering — a team of agents, ported from paperclipai/companies
# (companies/agentsys-engineering).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo  (discover-tasks, orchestrate-review)
#   ├─► cto  (drift-analysis, repo-intel, enhance-orchestrator)
#   │   ├─► research-perf-analyst  (perf-analyzer, perf-benchmarker, learn, consult, debate)
#   │   └─► staff-engineer  (deslop, validate-delivery, enhance-prompts)
#   └─► qa-release-lead  (orchestrate-review, validate-delivery, sync-docs)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/agentsys-engineering/team.rb \
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
research_perf_analyst = member("research-perf-analyst",
           "Research & Performance Analyst — You are activated on demand by the CEO " \
           "or CTO when the team needs: - Performance investigation for a specific " \
           "scenario - Research on a new topic, technology, or approach - A second " \
           "opinion from another AI tool - A structured debate to stress-test a " \
           "decision")

staff_engineer = member("staff-engineer",
           "Staff Software Engineer — You receive approved implementation plans from " \
           "the CTO — structured step-by-step actions with file paths, specific " \
           "changes, risks, and complexity assessments.")

cto = member("cto",
           "Chief Technology Officer — You receive prioritized tasks from the CEO " \
           "with full context: task description, priority level, and any known " \
           "constraints.",
           reports: [research_perf_analyst, staff_engineer])

qa_release_lead = member("qa-release-lead",
           "QA & Release Lead — You receive completed implementations from the Staff " \
           "Engineer — code that has passed deslop cleanup and delivery validation.")

TEAM = [cto, qa_release_lead].freeze

# The Chief Executive Officer's prompt is the company description (COMPANY.md body)
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
