#!/usr/bin/env ruby
# frozen_string_literal: true

# TÂCHES Creative — a team of agents, ported from paperclipai/companies
# (companies/taches-creative).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo  (create-plans, create-meta-prompts, context-handoff, todo-management, meta-prompting)
#   ├─► quality-auditor  (create-agent-skills, create-slash-commands, create-subagents)
#   ├─► research-lead  (research-competitive, research-deep-dive, research-feasibility, research-history, research-landscape, research-open-source, research-options, research-technical)
#   ├─► skills-architect  (create-agent-skills, create-subagents, create-mcp-servers, debug-like-expert, setup-ralph, iphone-apps-expertise, macos-apps-expertise, n8n-automations-expertise)
#   ├─► strategy-director  (consider-pareto, consider-first-principles, consider-inversion, consider-second-order, consider-5-whys, consider-occams-razor, consider-one-thing, consider-swot, consider-eisenhower-matrix, consider-10-10-10, consider-opportunity-cost, consider-via-negativa)
#   └─► workflow-designer  (create-slash-commands, create-hooks, todo-management, context-handoff)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/taches-creative/team.rb \
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
quality_auditor = member("quality-auditor",
           "Quality Auditor — You are activated when any deliverable needs review -- " \
           "a new skill, a slash command, a subagent configuration, or any Claude " \
           "Code extension that should be audited before deployment.")

research_lead = member("research-lead",
           "Research Lead — You are activated when the team needs information before " \
           "making decisions, when a project requires competitive analysis, " \
           "technical exploration, or feasibility assessment, or when anyone needs " \
           "structured research on a topic.")

skills_architect = member("skills-architect",
           "Skills Architect — You are activated when the team needs a new skill " \
           "created, an existing skill healed or improved, a subagent configured, an " \
           "MCP server built, or domain expertise established for a new technology " \
           "area.")

strategy_director = member("strategy-director",
           "Strategy Director — You are activated when a decision needs structured " \
           "analysis, when a team is stuck and needs a new perspective, or when " \
           "someone explicitly asks to \"consider\" a problem through a specific " \
           "lens.")

workflow_designer = member("workflow-designer",
           "Workflow Designer — You are activated when the team needs a new slash " \
           "command, a hook for event-driven automation, a todo management workflow, " \
           "or a context handoff process designed.")

TEAM = [quality_auditor, research_lead, skills_architect, strategy_director, workflow_designer].freeze

# The Creative Director's prompt is the company description (COMPANY.md body)
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
