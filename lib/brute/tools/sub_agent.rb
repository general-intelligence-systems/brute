# frozen_string_literal: true

require "bundler/setup"
require "brute"
require 'brute/turn/agent_pipeline'

module Brute
  module Tools
    # A SubAgent is an Agent that exposes a tool-shaped facade so it can
    # be dropped into another agent's tools list. The parent agent hands it
    # to the LLM as a regular tool; when invoked, the SubAgent runs its own
    # pipeline against a fresh Session built from the tool arguments, then
    # returns the final assistant message as the tool result.
    #
    # Usage:
    #
    #   researcher = Brute::Tools::SubAgent.new(
    #     name:        "research",
    #     description: "Delegate a research task to a read-only sub-agent.",
    #   ) do
    #     use Brute::Middleware::SystemPrompt
    #     use Brute::Middleware::Loop::ToolResult
    #     use Brute::Middleware::MaxIterations, max_iterations: 10
    #     use Brute::Middleware::ToolPipeline, tools: [Brute::Tools::FSRead, Brute::Tools::FSSearch]
    #     run ->(env) do
    #       ctx = RubyLLM.context { |c| c.ollama_api_base = ENV["OLLAMA_API_BASE"] }
    #       model, provider = RubyLLM::Models.resolve(
    #         "llama3.2", provider: :ollama, assume_exists: true, config: ctx.config)
    #       response = provider.complete(env[:messages],
    #                                    tools:       Brute.rubyllm_tools(env[:tools]),
    #                                    temperature: 0.7,
    #                                    model:       model)
    #       RubyLLM::MessageTransport.new(response).wrap_each { |m| env[:messages] << m }
    #     end
    #   end
    #
    #   # The SubAgent IS a tool — hand it to a parent agent's ToolPipeline:
    #   main_agent = Brute.agent do
    #     use Brute::Middleware::ToolPipeline, tools: [Brute::Tools::FSRead, researcher]
    #     run ->(env) { ... }
    #   end
    #   main_agent.start("delegate some research")
    #
    class SubAgent < Brute::Turn::AgentPipeline
      DEFAULT_PARAMS = {
        task: { type: "string", desc: "A clear, detailed description of the task", required: true },
      }.freeze

      attr_reader :sub_agent_name, :description, :params

      def initialize(name:, description:, params: DEFAULT_PARAMS, &block)
        @sub_agent_name = name.to_s
        @description    = description
        @params         = params
        super(&block)
      end

      # Tool-shaped entry point. Builds a session from arguments, runs the
      # agent loop, returns the last assistant message as a string.
      def execute(arguments)
        session = build_session(arguments)
        start(session)
        extract_result(session)
      end

      # Adapter so the parent agent's completion middleware (and ruby_llm)
      # sees this as a regular tool. ToolPipeline middleware should call
      # `to_ruby_llm` when building the tools hash if a tool responds to it.
      def to_ruby_llm
        sub = self
        Class.new(::RubyLLM::Tool) do
          description sub.description
          sub.params.each { |k, opts| param k, **opts }
          define_method(:name) { sub.sub_agent_name }
          define_method(:execute) { |**args| sub.execute(args) }
        end.new
      end

      # Lets ToolPipeline treat SubAgents the same as RubyLLM::Tool instances
      # without checking respond_to? everywhere.
      def name
        @sub_agent_name
      end

      private

        def build_session(arguments)
          task = arguments[:task] || arguments["task"]
          Brute.log.tap { |s| s.user(task) }
        end

        def extract_result(session)
          last = session.reverse_each.find do |m|
            m.role == :assistant && m.content.is_a?(String) && !m.content.empty?
          end
          last&.content || "(sub-agent completed but produced no text response)"
        end
    end
  end
end

__END__

describe "brute/tools/sub_agent" do
  it "exposes a name matching the sub-agent identifier" do
    sa = Brute::Tools::SubAgent.new(name: "research", description: "test") do
      run ->(env) { env[:messages].assistant("done") }
    end
    sa.name.should == "research"
  end

  it "execute returns the last assistant message" do
    sa = Brute::Tools::SubAgent.new(name: "research", description: "test") do
      run ->(env) { env[:messages].assistant("result text") }
    end
    sa.execute(task: "do something").should == "result text"
  end
end
