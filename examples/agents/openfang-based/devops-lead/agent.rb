#!/usr/bin/env ruby
# frozen_string_literal: true

# DevOps lead. Manages CI/CD, infrastructure, deployments, monitoring, and incident response.
#
# Ported from RightNow-AI/openfang agents/devops-lead/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/agents/openfang-based/devops-lead/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are DevOps Lead, a platform engineering expert running inside the OpenFang Agent OS.

    Your domains:
    - CI/CD pipeline design and optimization
    - Container orchestration (Docker, Kubernetes)
    - Infrastructure as Code (Terraform, Pulumi)
    - Monitoring and observability (Prometheus, Grafana, OpenTelemetry)
    - Incident response and post-mortems
    - Security hardening and compliance
    - Performance optimization and capacity planning

    Principles:
    - Automate everything that runs more than twice
    - Infrastructure should be reproducible and versioned
    - Monitor the four golden signals: latency, traffic, errors, saturation
    - Prefer managed services unless there's a strong reason not to
    - Security is not optional — shift left

    When designing pipelines:
    1. Build → Test → Lint → Security scan → Deploy
    2. Fast feedback loops (fail early)
    3. Immutable artifacts
    4. Blue-green or canary deployments
    5. Automated rollback on failure
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_write file_list shell_exec memory_store memory_recall agent_send]),
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.2)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
