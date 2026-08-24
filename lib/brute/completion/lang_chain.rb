# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/hooks"

module Brute
  module Completion
    # Completion backed by the langchainrb gem
    # (https://github.com/patterns-ai-core/langchainrb). Its LLM classes wrap
    # many providers; build one and hand it over:
    #
    #   Brute.agent
    #     .use(Brute::Middleware::SystemPrompt)
    #     .run(Brute::Completion::LangChain.new(
    #       llm: Langchain::LLM::OpenAI.new(api_key: ENV["OPENAI_API_KEY"]),
    #     ))
    #
    #   llm:         a Langchain::LLM instance (required; client: is an alias)
    #   model:       model id override (falls back to env[:model], then the
    #                llm instance's own default)
    #   tools:       tools list, any shape Tools::Adapter accepts
    #   temperature: sampling temperature (default 0.7)
    class LangChain
      include Brute::Hooks

      DEFAULT_TEMPERATURE = 0.7

      def initialize(llm: nil, client: nil, **options)
        # Brute depends on no LLM library: the provider gem is required here,
        # at point of use, and only for this completion.
        begin
          require "langchain"
        rescue LoadError
          raise LoadError, "#{self.class} needs the 'langchainrb' gem — add `gem \"langchainrb\"` to your Gemfile."
        end

        @llm = llm || client or
          raise ArgumentError, "#{self.class} needs an llm: option, e.g. Langchain::LLM::OpenAI.new(api_key: ...)"

        @options = options
      end

      def call(env)
        emit(BEFORE_LLM_EVENT, env)

        response = nil
        emit(LLM_DURATION_EVENT, env) { response = @llm.chat(**params(env)) }

        if (usage = Brute::MessageTransport::LangChain.usage_metrics(response))
          (env[:metadata] ||= {})[:last_llm_usage] = usage
        end

        # langchainrb speaks the OpenAI-style wire format both ways.
        Brute::MessageTransport::LangChain.wrap_each(reply(response)) do |message|
          env[:messages] << message
        end

        emit(AFTER_LLM_EVENT, env)
        env
      rescue => error
        emit(LLM_FAILURE_EVENT, env)

        if defined?(::Faraday::Error) && error.is_a?(::Faraday::Error)
          emit(FARADAY_ERROR_EVENT, env, error)
        else
          emit(STANDARD_ERROR_EVENT, env, error)
        end

        env
      end

      private

        attr_reader :options

        def params(env)
          params = {
            messages:    Brute::MessageTransport::LangChain.dump_all(env[:messages]),
            temperature: temperature(env),
          }

          tools = tool_definitions(env)
          params[:tools] = tools if tools.any?

          model = option(env, :model)
          params[:model] = model if model

          params
        end

        def reply(response)
          {
            "role"       => "assistant",
            "content"    => response.chat_completion,
            "tool_calls" => Array(response.tool_calls),
          }
        end

        def tool_definitions(env)
          Brute::Tools::Adapter.wrap_all(option(env, :tools) || []).values.map do |adapter|
            { type: "function", function: adapter.to_h }
          end
        end

        def option(env, key) = options.fetch(key) { env[key] }

        def temperature(env) = options.fetch(:temperature) { env.fetch(:temperature, DEFAULT_TEMPERATURE) }
    end
  end
end

__END__

describe "brute/completion/lang_chain" do
  require "brute/messages"

  # langchainrb's own suite fakes the LLM with `receive(:chat)` returning a
  # response that answers chat_completion / tool_calls; this is that shape.
  FakeLangChainResponse = Struct.new(:chat_completion, :tool_calls) unless defined?(FakeLangChainResponse)

  FakeLangChainLLM = Class.new do
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def chat(**params)
      @calls << params
      @response
    end
  end unless defined?(FakeLangChainLLM)

  it "sends the log as OpenAI-style messages and appends the reply, tool calls included" do
    response = FakeLangChainResponse.new("via langchain", [])
    llm = FakeLangChainLLM.new(response)

    env = { messages: Brute.log, tools: [], events: [] }
    env[:messages].user("hi")

    seen = []
    pipeline = Brute::Turn::Pipeline.new
    pipeline.run Brute::Completion::LangChain.new(llm: llm, model: "gpt-4o-mini")
    pipeline.on(Brute::Hooks::BEFORE_LLM_EVENT) { |_env| seen << :before }
    pipeline.on(Brute::Hooks::AFTER_LLM_EVENT) { |_env| seen << :after }
    pipeline.call(env)

    env[:messages].last.role.should == :assistant
    env[:messages].last.content.should == "via langchain"
    seen.should == [:before, :after]

    llm.calls.first[:model].should == "gpt-4o-mini"
    llm.calls.first[:temperature].should == 0.7
    llm.calls.first[:messages].first[:role].should == "user"

    # A tool call comes back in the OpenAI shape and lands as a ToolCall.
    calling = FakeLangChainLLM.new(FakeLangChainResponse.new(nil, [
      { "id" => "tc1", "type" => "function", "function" => { "name" => "echo", "arguments" => { "text" => "hi" } } },
    ]))
    tool_env = { messages: Brute.log, tools: [], events: [] }
    tool_env[:messages].user("call it")
    Brute::Turn::Pipeline.new.tap { |p| p.run Brute::Completion::LangChain.new(llm: calling) }.call(tool_env)
    tool_env[:messages].last.tool_calls.first.name.should == "echo"

    # A raising provider is reported through the hooks, not up the stack.
    boom = Object.new
    boom.define_singleton_method(:chat) { |**_params| raise "no route to host" }
    failed = []
    failing = Brute::Turn::Pipeline.new
    failing.run Brute::Completion::LangChain.new(llm: boom)
    failing.on(Brute::Hooks::STANDARD_ERROR_EVENT) { |_env, error| failed << error.message }

    error_env = { messages: Brute.log, tools: [], events: [] }
    error_env[:messages].user("hi")
    failing.call(error_env)
    failed.should == ["no route to host"]

    # An llm is not optional.
    should.raise(ArgumentError) { Brute::Completion::LangChain.new }
  end
end
