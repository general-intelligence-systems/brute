#!/usr/bin/env ruby
# frozen_string_literal: true

# MiniMax Studio — a team of agents, ported from paperclipai/companies
# (companies/minimax-studio, itself generated from MiniMax-AI/skills).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each specialist's skills under agents/<name>/.brute/skills); this file
# only does the wiring. The CEO is the hub — each specialist is a
# Brute::Tools::SubAgent in the CEO's tool list, exactly the org chart
# the company describes:
#
#   ceo ──► app-engineer       (frontend-dev, fullstack-dev)
#       ──► mobile-engineer    (android-native-dev, ios-application-dev)
#       ──► graphics-engineer  (shader-dev, gif-sticker-maker)
#       ──► document-producer  (minimax-pdf, minimax-docx, minimax-xlsx, pptx-generator)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   export MINIMAX_API_KEY=...   # optional — used by some skills
#   bundle exec ruby examples/ports/paperclip/minimax-studio/team.rb \
#     "Build me a landing page for a coffee subscription service"

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

# Build one specialist as a SubAgent: verbatim AGENTS.md body as its
# system prompt, its own skills dir, and the studio's working tools.
def specialist(name, description)
  _meta, body = load_agent_md(File.join(agent_dir(name), "AGENTS.md"))

  prompt = Brute::SystemPrompt.build do |p, ctx|
    p << body
    skills = Brute::Prompts::Skills.call(ctx.merge(cwd: agent_dir(name)))
    p << skills if skills
  end

  Brute::Tools::SubAgent.new(
    name:        name,
    description: description,
    provider:    Brute.provider,
    model:       MODEL,
    tools:       Brute::Tools::ALL,
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

# Specialist descriptions come from each agent's "Where work comes from"
# section — the same routing the CEO's AGENTS.md describes.
TEAM = [
  specialist("app-engineer",
             "Delegate web application development — landing pages, marketing sites, " \
             "dashboards, admin panels, full-stack apps, or API services."),
  specialist("mobile-engineer",
             "Delegate native mobile app development — Android apps, iOS apps, or " \
             "cross-platform native projects requiring platform-specific implementations."),
  specialist("graphics-engineer",
             "Delegate visual effects, shaders, or creative media — GLSL shaders, ShaderToy " \
             "creations, ray marching scenes, procedural art, animated GIF stickers, or any " \
             "work requiring real-time graphics programming."),
  specialist("document-producer",
             "Delegate document creation, editing, or formatting — reports, proposals, " \
             "resumes, spreadsheets, presentations, contracts, forms, or any work whose " \
             "output is a professional document."),
].freeze

# The CEO's prompt is the company description (COMPANY.md body) plus the
# CEO's own AGENTS.md, both verbatim.
_company_meta, company_body = load_agent_md(File.join(__dir__, "COMPANY.md"))
_ceo_meta, ceo_body         = load_agent_md(File.join(agent_dir("ceo"), "AGENTS.md"))

CEO_PROMPT = Brute::SystemPrompt.build do |p, _ctx|
  p << company_body
  p << ceo_body
  p << "Specialists are available as tools — call one to delegate, passing the full " \
       "task context. Synthesize their results before replying to the user."
end

ceo = Brute::Agent.new(
  provider: Brute.provider,
  model:    MODEL,
  tools:    TEAM,
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: CEO_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

request = ARGV.join(" ")
request = "Introduce the studio: who's on the team and what can each of them do?" if request.empty?

session = Brute::Session.new
session.user(request)
ceo.call(session)
