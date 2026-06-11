#!/usr/bin/env ruby
# frozen_string_literal: true

# A provider-agnostic calendar agent, ported from
# inference-gateway/google-calendar-agent.
#
# An agent is just prompt + tools + skills — the architecture is already
# solved by the brute gem:
#
#   prompt — the upstream agent's system prompt (main.go), verbatim with
#            the provider name interpolated
#   tools  — examples/calendar_agent/tools.rb (the upstream tool set as
#            plain hashes, defined against the Provider interface)
#   skills — examples/calendar_agent/.brute/skills/**/SKILL.md
#
# The provider is swappable (issue #15): GoogleCalendar talks to the real
# Calendar v3 API; InMemory is the upstream's "mock mode" and runs with no
# credentials. Copy providers/google_calendar.rb to add CalDAV, Office 365, etc.
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/calendar_agent/agent.rb "What's on my calendar today?"
#
#   # against real Google Calendar:
#   export GOOGLE_CALENDAR_ACCESS_TOKEN=$(gcloud auth print-access-token \
#     --scopes=https://www.googleapis.com/auth/calendar)
#   export GOOGLE_CALENDAR_ID=primary
#   bundle exec ruby examples/calendar_agent/agent.rb "Schedule a 30-min sync tomorrow morning"

require "bundler/setup"
require "brute"
require_relative "tools"
require_relative "providers/google_calendar"
require_relative "providers/in_memory"

provider =
  if ENV["GOOGLE_CALENDAR_ACCESS_TOKEN"]
    CalendarAgent::Providers::GoogleCalendar.new
  else
    $stderr.puts "GOOGLE_CALENDAR_ACCESS_TOKEN not set — using the in-memory demo provider".light_black
    CalendarAgent::Providers::InMemory.new
  end

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, ctx|
  prompt << <<~PROMPT
    You are a #{provider.display_name} AI agent specialized in calendar management and scheduling operations.

    Your primary capabilities:
    1. **Event Management**: Create, update, delete, and retrieve calendar events
    2. **Scheduling Intelligence**: Find available time slots and check for conflicts
    3. **Calendar Operations**: List events with flexible time ranges and search queries

    Key features:
    - Support for both mock mode (demo/testing) and production #{provider.display_name} API
    - RFC3339 timestamp handling for accurate scheduling
    - Intelligent conflict detection and availability checking
    - Attendee management and location tracking
    - Comprehensive event search and filtering

    When helping users:
    - Always validate time formats and ranges
    - Provide clear feedback on scheduling conflicts
    - Suggest alternative time slots when conflicts are detected
    - Handle both simple and complex scheduling scenarios
    - Maintain data accuracy and consistency with #{provider.display_name}

    Time and timezone handling:
    - For any time-relative request ("today", "tomorrow", "next Friday",
      "in 2 hours"), call the get_current_datetime tool FIRST to anchor
      the current time and the user's IANA timezone. Do not guess.
    - Emit RFC3339 timestamps with the offset of the user's timezone
      (e.g. 2026-05-20T14:00:00+02:00 for CEST), not UTC and not a
      provider-default like Pacific Time.
    - If the user names an explicit timezone, prefer that over the
      configured default.

    Your responses should be accurate, helpful, and focused on calendar management tasks.
  PROMPT

  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: __dir__))
  prompt << skills if skills
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    CalendarAgent::Tools.build(provider),
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

question = ARGV.join(" ")
question = "What's on my calendar today?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
