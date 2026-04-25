# frozen_string_literal: true

# Shared helpers for Brute examples.
#
# Usage:
#   require_relative "helper"
#
#   provider_for_example :ollama
#
#   @session = Brute::Store::Session.new
#   @model   = "tinyllama"
#
#   agent = Brute::Agent.new(
#     provider: @provider,
#     model: @model,
#     system_prompt: system_prompt,
#   )
#
#   step = Brute::Loop::AgentTurn.perform(
#     agent: agent,
#     session: @session,
#     pipeline: full_pipeline,
#     input: "Hi",
#   )
#

require_relative "../lib/brute"

module ExampleHelper
  # Select a provider for the example. Sets @provider as a side effect
  # so that system_prompt, full_pipeline, and Brute::Agent.new can
  # reference it.
  #
  #   provider_for_example :ollama
  #   provider_for_example :anthropic
  #   provider_for_example :opencode
  #
  def provider_for_example(name)
    @provider = case name.to_sym
    when :ollama
      ensure_ollama!
      Brute::Providers::Ollama.new
    when :anthropic
      Brute::Patches::AnthropicToolRole.apply!
      LLM.anthropic(key: ENV.fetch("ANTHROPIC_API_KEY"))
    when :openai
      LLM.openai(key: ENV.fetch("OPENAI_API_KEY"))
    when :google
      LLM.google(key: ENV.fetch("GOOGLE_API_KEY"))
    when :deepseek
      LLM.deepseek(key: ENV.fetch("LLM_API_KEY"))
    when :xai
      LLM.xai(key: ENV.fetch("LLM_API_KEY"))
    when :opencode, :opencode_zen
      LLM::OpencodeZen.new(key: ENV.fetch("OPENCODE_API_KEY", "public"))
    when :opencode_go
      LLM::OpencodeGo.new(key: ENV.fetch("OPENCODE_API_KEY", "public"))
    else
      Brute::Providers.guess_from_env || raise("Unknown provider: #{name}")
    end
  end

  # Build the provider-aware system prompt via Brute::SystemPrompt.
  #
  # Reads @provider, and optionally @model, @custom_rules from the
  # calling scope.
  #
  #   @custom_rules = "Always use frozen_string_literal."
  #   prompt = system_prompt
  #
  def system_prompt
    provider = @provider || raise("Call provider_for_example before system_prompt")
    model    = @model || provider.default_model

    Brute::SystemPrompt.default.prepare(
      provider_name: provider.name.to_s,
      model_name:    model.to_s,
      cwd:           Dir.pwd,
      custom_rules:  @custom_rules,
      agent:         nil,
    ).to_s
  end

  # Build the full production middleware pipeline.
  #
  # Reads @provider and @session from the calling scope. Uses
  # system_prompt for compaction context. Optionally reads @tools.
  #
#   @session = Brute::Store::Session.new
#   pipeline = full_pipeline
  #   pipeline = full_pipeline(reasoning: { effort: :high })
  #
  def full_pipeline(reasoning: {})
    session       = @session  || raise("Set @session before calling full_pipeline")
    provider      = @provider || raise("Call provider_for_example before full_pipeline")
    sys_prompt    = system_prompt
    tools         = @tools || Brute::Tools::ALL
    message_store = session.message_store
    logger        = Logger.new($stderr, level: Logger::INFO)

    Brute::Middleware::Stack.new do
      use Brute::Middleware::OTel::Span
      use Brute::Middleware::Tracing, logger: logger
      use Brute::Middleware::OTel::ToolResults
      use Brute::Middleware::MaxIterations
      use Brute::Middleware::ToolResultPrep
      use Brute::Middleware::Retry
      use Brute::Middleware::SessionPersistence, session: session
      use Brute::Middleware::MessageTracking, store: message_store
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

  # Default callbacks that print agent activity to stdout in real-time.
  #
  #   step = Brute::Loop::AgentTurn.perform(
  #     agent: agent, session: @session, pipeline: full_pipeline,
  #     input: "Hi", callbacks: default_callbacks,
  #   )
  #
  def default_callbacks
    {
      on_content: ->(text) { print text; $stdout.flush },
      on_tool_call_start: ->(batch) {
        batch.each { |tc| puts "\n--- tool: #{tc[:name]} ---" }
      },
      on_tool_result: ->(name, _result) {
        puts "--- #{name} done ---\n"
      },
    }
  end

  private

  def ensure_ollama!
    return if system("pgrep -x ollama > /dev/null 2>&1")
    spawn("ollama serve", out: "/dev/null", err: "/dev/null")
    sleep 2
  end
end

include ExampleHelper
