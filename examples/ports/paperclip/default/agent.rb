#!/usr/bin/env ruby
# frozen_string_literal: true

# Default agent templates, ported from paperclipai/companies
# (companies/default).
#
# Unlike the other companies in the catalog, `default` is not an org chart —
# it is two standalone agent templates in the workspace format, where an
# agent is four sibling markdown files instead of one AGENTS.md:
#
#   AGENTS.md    -- entrypoint instructions
#   SOUL.md      -- who the agent is and how it should act
#   TOOLS.md     -- tools the agent knows it has
#   HEARTBEAT.md -- checklist the agent runs every time it wakes
#
# All four are kept verbatim and concatenated into the system prompt, in the
# order the upstream runtime has the agent read them: identity first, then
# tools, then the operational checklist.
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/default/agent.rb ceo "<task>"
#   bundle exec ruby examples/ports/paperclip/default/agent.rb default "<task>"

require "bundler/setup"
require "brute"

MODEL = "claude-sonnet-4-20250514"

ROLES = %w[ceo default].freeze

role = ROLES.include?(ARGV.first) ? ARGV.shift : "default"
role_dir = File.join(__dir__, role)

# The workspace files, verbatim, in reading order.
PROMPT = Brute::SystemPrompt.build do |p, _ctx|
  %w[AGENTS.md SOUL.md TOOLS.md HEARTBEAT.md].each do |file|
    p << File.read(File.join(role_dir, file)).strip
  end
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    MODEL,
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

request = ARGV.join(" ")
request = "Introduce yourself: who are you and how do you work?" if request.empty?

session = Brute::Session.new
session.user(request)
agent.call(session)
