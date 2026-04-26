# frozen_string_literal: true

require "bundler/setup"
require "brute"
require 'brute/pipeline'

module Brute
  # A SubAgent is an Agent that exposes a tool-shaped facade so it can
  # be dropped into another agent's tools list. The parent agent's
  # LLMCall passes it to ruby_llm as a regular tool; when invoked, the
  # SubAgent runs its own pipeline against a fresh Session built from
  # the tool arguments, then returns the final assistant message as the
  # tool result.
  #
  # Usage:
  #
  #   researcher = Brute::SubAgent.new(
  #     name:        "research",
  #     description: "Delegate a research task to a read-only sub-agent.",
  #     provider:    Brute.provider,
  #     model:       Brute.provider.default_model,
  #     tools:       [Brute::Tools::FSRead, Brute::Tools::FSSearch],
  #   ) do
  #     use Brute::Middleware::SystemPrompt
  #     use Brute::Middleware::MaxIterations, max_iterations: 10
  #     use Brute::Middleware::ToolCall
  #     run Brute::Middleware::LLMCall.new
  #   end
  #
  #   main_agent = Brute::Agent.new(
  #     provider: ...,
  #     tools: [Brute::Tools::FSRead, researcher],   # SubAgent IS a tool
  #   ) { ... }
  #
  class SubAgent < Agent
    DEFAULT_PARAMS = {
      task: { type: "string", desc: "A clear, detailed description of the task", required: true },
    }.freeze

    attr_reader :sub_agent_name, :description, :params

    def initialize(name:, description:, params: DEFAULT_PARAMS, **agent_opts, &block)
      @sub_agent_name = name.to_s
      @description    = description
      @params         = params
      super(**agent_opts, &block)
    end

    # Tool-shaped entry point. Builds a session from arguments, runs the
    # agent loop, returns the last assistant message as a string.
    def execute(arguments)
      session = build_session(arguments)
      call(session)
      extract_result(session)
    end

    # Adapter so the parent agent's LLMCall (and ruby_llm) sees this as
    # a regular tool. ToolCall middleware should call `to_ruby_llm` when
    # building the tools hash if a tool responds to it.
    def to_ruby_llm
      sub = self
      Class.new(RubyLLM::Tool) do
        description sub.description
        sub.params.each { |k, opts| param k, **opts }
        define_method(:name) { sub.sub_agent_name }
        define_method(:execute) { |**args| sub.execute(args) }
      end.new
    end

    # Lets ToolCall treat SubAgents the same as RubyLLM::Tool instances
    # without checking respond_to? everywhere.
    def name
      @sub_agent_name
    end

    private

      def build_session(arguments)
        task = arguments[:task] || arguments["task"]
        Brute::Session.new.tap { |s| s.user(task) }
      end

      def extract_result(session)
        last = session.reverse_each.find do |m|
          m.role == :assistant && m.content.is_a?(String) && !m.content.empty?
        end
        last&.content || "(sub-agent completed but produced no text response)"
      end
  end
end

test do
  it "exposes a name matching the sub-agent identifier" do
    # not implemented
  end

  it "execute returns the last assistant message" do
    # not implemented
  end
end
