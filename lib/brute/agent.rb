# frozen_string_literal: true

require "bundler/setup"
require "brute"
require 'brute/pipeline'

module Brute
  DEFAULT_SYSTEM_PROMPT = "You are a helpful assistant, hellbent on taking over the world."

  # An agent is a Pipeline configured for LLM turns. It carries the
  # provider/model/tools configuration and shapes env from a Session
  # (the conversation message log).
  #
  # Usage:
  #
  #   agent = Brute::Agent.new(
  #     provider: Brute.provider,
  #     model:    "claude-sonnet-4-20250514",
  #     tools:    Brute::Tools::ALL,
  #   ) do
  #     use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  #     use Brute::Middleware::SystemPrompt
  #     use Brute::Middleware::MaxIterations
  #     use Brute::Middleware::Question
  #     use Brute::Middleware::ToolCall
  #     run Brute::Middleware::LLMCall.new
  #   end
  #
  #   session = Brute::Session.new
  #   session.user("fix the failing tests")
  #   agent.call(session)
  #
  class Agent < Pipeline
    attr_reader :provider, :model, :tools

    def initialize(provider:, model: nil, tools: [], &block)
      @provider = provider
      @model    = model
      @tools    = tools
      super(&block)
    end

    # Run one turn against the given session. The session is mutated
    # in place (assistant + tool messages appended) and returned.
    def call(session, events: NullSink.new)
      env = {
        messages:          session,
        provider:          @provider,
        model:             @model,
        tools:             @tools,
        events:            events,
        metadata:          {},
        system_prompt:     DEFAULT_SYSTEM_PROMPT,
        current_iteration: 1,
      }
      super(env)
      session
    end
  end
end

test do
  it "runs a turn and returns the session" do
    # not implemented — needs a stub provider
  end

  it "passes provider/model/tools through env" do
    captured = nil
    capture = ->(env) { captured = env.slice(:provider, :model, :tools) }

    agent = Brute::Agent.new(provider: :stub, model: "m", tools: [:a]) { run capture }
    agent.call(Brute::Session.new)
    captured.should == { provider: :stub, model: "m", tools: [:a] }
  end
end
