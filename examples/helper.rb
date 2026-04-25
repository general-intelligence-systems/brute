# frozen_string_literal: true

# Shared helpers for Brute examples.
#
# Usage:
#   require_relative "helper"
#
#   agent = Brute::Agent.new(
#     provider: provider,
#     model: nil,
#     system_prompt: system_prompt,
#   )
#
#   step = Brute::Loop::AgentTurn.perform(
#     agent: agent,
#     session: Brute::Store::Session.new,
#     pipeline: full_pipeline,
#     input: "Hi",
#   )
#

require "pp"
require_relative "../lib/brute"

module ExampleHelper
  # Returns the provider detected from environment variables.
  # Delegates to Brute::Providers.guess_from_env.
  def provider
    @provider ||= begin
      p = Brute::Providers.guess_from_env || raise(
        "No provider detected. Set one of: ANTHROPIC_API_KEY, OPENAI_API_KEY, " \
        "GOOGLE_API_KEY, LLM_API_KEY, OPENCODE_API_KEY, or OLLAMA_HOST"
      )
      puts "[brute] Provider: #{p.name} (model: #{p.default_model})"
      p
    end
  end

  # Build the provider-aware system prompt via Brute::SystemPrompt.
  #
  # Optionally reads @custom_rules from the calling scope.
  #
  #   @custom_rules = "Always use frozen_string_literal."
  #   prompt = system_prompt
  #
  def system_prompt
    model = provider.default_model

    Brute::SystemPrompt.default.prepare(
      provider_name: provider.name.to_s,
      model_name:    model.to_s,
      cwd:           Dir.pwd,
      custom_rules:  @custom_rules,
      agent:         nil,
    ).to_s
  end

  # Build the full production middleware stack.
  #
  # Reads @session from the calling scope. Uses system_prompt for
  # compaction context. Optionally reads @tools.
  #
  #   @session = Brute::Store::Session.new
  #   stack = full_pipeline
  #   stack = full_pipeline(reasoning: { effort: :high })
  #
  def full_pipeline(reasoning: {})
    session       = @session  || raise("Set @session before calling full_pipeline")
    sys_prompt    = system_prompt
    tools         = @tools || Brute::Tools::ALL
    logger        = Logger.new($stderr, level: Logger::INFO)

    Brute::Middleware::Stack.new do
      use Brute::Middleware::OTel::Span
      use Brute::Middleware::Tracing, logger: logger
      use Brute::Middleware::OTel::ToolResults
      use Brute::Middleware::MaxIterations
      use Brute::Middleware::ToolResultPrep
      use Brute::Middleware::Retry
      use Brute::Middleware::SessionPersistence, session: session
      use Brute::Middleware::TokenTracking
      use Brute::Middleware::OTel::TokenUsage

      use Brute::Middleware::CompactionCheck,
        system_prompt: sys_prompt

      use Brute::Middleware::ToolErrorTracking
      use Brute::Middleware::DoomLoopDetection

      unless reasoning.empty?
        use Brute::Middleware::ReasoningNormalizer, **reasoning
      end

      use Brute::Middleware::ToolCall
      use Brute::Middleware::Question
      use Brute::Middleware::ToolUseGuard
      use Brute::Middleware::OTel::ToolCalls
      use Brute::Middleware::PendingToolCollection
      run Brute::Middleware::LLMCall.new
    end
  end

  # Print all session events in grey using pp formatting.
  #
  # Expects @session to be set in the calling scope.
  #
  #   @session = Brute::Store::Session.new
  #   # ... run agent ...
  #   print_events
  #
  def print_events(session = @session)
    session.message_store.events.each do |event|
      puts
      puts event.pretty_inspect.light_black
    end
  end

end

include ExampleHelper

$stderr.puts Brute::LOGO.light_black
