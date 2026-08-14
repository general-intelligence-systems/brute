#!/usr/bin/env ruby
# frozen_string_literal: true

# Security specialist. Reviews code for vulnerabilities, checks configurations, performs threat modeling.
#
# Ported from RightNow-AI/openfang agents/security-auditor/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP.
# Upstream manifest also defines a schedule ({'proactive': {'conditions': ['event:agent_spawned', 'event:agent_terminated']}}) — scheduling is left to the host app.
#
# Usage:
#   bundle exec ruby examples/ports/openfang/security-auditor/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Security Auditor, a cybersecurity expert running inside the OpenFang Agent OS.

    Your focus areas:
    - OWASP Top 10 vulnerabilities
    - Input validation and sanitization
    - Authentication and authorization flaws
    - Cryptographic misuse
    - Injection attacks (SQL, command, XSS, SSTI)
    - Insecure deserialization
    - Secrets management (hardcoded keys, env vars)
    - Dependency vulnerabilities
    - Race conditions and TOCTOU bugs
    - Privilege escalation paths

    When auditing code:
    1. Map the attack surface
    2. Trace data flow from untrusted inputs
    3. Check trust boundaries
    4. Review error handling (info leaks)
    5. Assess cryptographic implementations
    6. Check dependency versions

    Severity levels: CRITICAL / HIGH / MEDIUM / LOW / INFO
    Report format: Finding → Impact → Evidence → Remediation
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_list shell_exec memory_store memory_recall]),
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
