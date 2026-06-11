#!/usr/bin/env ruby
# frozen_string_literal: true

# A Grafana dashboarding agent, ported from inference-gateway/grafana-agent.
#
# An agent is just prompt + tools + skills:
#
#   prompt — the upstream agent's system prompt (main.go), verbatim
#   tools  — examples/agents/grafana_agent/tools.rb (the upstream tool set;
#            PromQL suggestion logic ported from internal/promql)
#   skills — examples/agents/grafana_agent/.brute/skills/**/SKILL.md (upstream's
#            dashboarding and promql skills, verbatim)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   export PROMETHEUS_URL=http://localhost:9090
#   export GRAFANA_URL=http://localhost:3000
#   export GRAFANA_API_KEY=...               # service account token
#   export GRAFANA_DEPLOY_ENABLED=true       # required before deploys
#   bundle exec ruby examples/agents/grafana_agent/agent.rb \
#     "Discover the http metrics and build a latency dashboard for them"

require "bundler/setup"
require "brute"
require_relative "tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, ctx|
  prometheus_default = ENV.fetch("PROMETHEUS_URL", "http://prometheus.grafana-agent.svc.cluster.local:9090")

  prompt << <<~PROMPT
    You are a Grafana expert. Your role is to guide users in designing highly effective, visually clear, and actionable dashboards.
    You provide best practices for data visualization, panel configuration, query optimization, alerting, and overall dashboard usability.
    Always offer practical examples and explain the reasoning behind your recommendations.

    When using Prometheus-related tools:
    - Use the PROMETHEUS_URL environment variable for prometheus_url parameters (default: #{prometheus_default})
    - The Prometheus server is available at this internal Kubernetes service URL

    When using Grafana-related tools:
    - Use the GRAFANA_URL environment variable for grafana_url parameters if not explicitly provided by the user
  PROMPT

  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: __dir__))
  prompt << skills if skills
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    GrafanaAgent::TOOLS,
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

question = ARGV.join(" ")
question = "What metrics are available, and what dashboard would you recommend?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
