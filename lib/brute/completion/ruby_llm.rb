# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/hooks"

module Brute
  module Completion
    # Completion backed by the ruby_llm gem.
    #
    #   Brute.agent
    #     .use(Brute::Middleware::SystemPrompt)
    #     .run(Brute::Completion::RubyLLM.new(provider: :ollama, model: "llama3.2:latest"))
    #
    # Anything not given at point of use falls back to env, so a pipeline that
    # sets env[:provider] / env[:model] still flows through.
    #
    #   provider:    LLM provider name (falls back to env[:provider])
    #   model:       model id (falls back to env[:model])
    #   tools:       tools list, any shape Tools::Adapter accepts
    #   temperature: sampling temperature (default 0.7)
    #   streaming:   stream chunks as :content / :reasoning events
    #   client:      injectable completion client (tests, custom transports);
    #                anything responding to complete(messages, **kwargs)
    class RubyLLM
      include Brute::Hooks

      DEFAULT_TEMPERATURE = 0.7

      # A Brute tool adapter wearing the interface ruby_llm's providers read
      # off a RubyLLM::Tool: name, description, and a params_schema (they fall
      # back to #parameters only when that is nil), plus #provider_params to
      # deep-merge into the declaration. Brute's own ToolPipeline runs the
      # tool, so this mostly has to describe it — #call is here for a caller
      # that hands the same list to ruby_llm's dispatch.
      class Tool
        def initialize(adapter)
          @adapter = adapter
        end

        def name            = @adapter.name
        def description     = @adapter.description
        def params_schema   = @adapter.to_h[:parameters]
        def parameters      = {}
        def provider_params = {}
        def call(args)      = @adapter.call(args)
      end

      def initialize(**options)
        # Brute depends on no LLM library: the provider gem is required here,
        # at point of use, and only for this completion.
        begin
          require "ruby_llm"
        rescue LoadError
          raise LoadError, "#{self.class} needs the 'ruby_llm' gem — add `gem \"ruby_llm\"` to your Gemfile."
        end

        @options = options
      end

      def call(env)
        emit(BEFORE_LLM_EVENT, env)

        messages = Brute::MessageTransport::RubyLLM.dump_all(env[:messages])
        response = nil
        emit(LLM_DURATION_EVENT, env) { response = complete(env, messages) }

        unless response.nil?
          if (usage = Brute::MessageTransport::RubyLLM.usage_metrics(response))
            (env[:metadata] ||= {})[:last_llm_usage] = usage
          end

          Brute::MessageTransport::RubyLLM.wrap_each(response) do |message|
            env[:messages] << message
          end
        end

        emit(AFTER_LLM_EVENT, env)
        env
      # A provider call that raises is reported through the hooks rather than
      # up the stack, the same way the OpenRouter completion does it.
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

        def complete(env, messages)
          kwargs = {
            model:       resolve_model(option(env, :model), option(env, :provider)),
            tools:       ruby_llm_tools(env),
            temperature: temperature(env),
          }

          provider_client = client(option(env, :provider))

          # Streaming reports through env[:events] chunk by chunk; the final
          # message still comes back for the log.
          if streaming?(env)
            provider_client.complete(messages, **kwargs) do |chunk|
              stream(env, chunk)
            end
          else
            provider_client.complete(messages, **kwargs)
          end
        end

        def stream(env, chunk)
          if chunk.content && !chunk.content.to_s.empty?
            env[:events] << { type: :content, data: chunk.content.to_s }
          end

          if chunk.respond_to?(:thinking) && chunk.thinking.respond_to?(:text) && chunk.thinking&.text
            env[:events] << { type: :reasoning, data: chunk.thinking.text }
          end
        end

        def client(provider)
          options[:client] || ::RubyLLM::Provider.resolve(provider).new(Brute.config)
        end

        # Look the model up in ruby_llm's registry; fall back to the raw id for
        # models the registry doesn't know (custom endpoints, injected clients).
        def resolve_model(model, provider)
          ::RubyLLM.models.find(model, provider)
        rescue StandardError
          model
        end

        # Point-of-use option, falling back to env.
        def option(env, key) = options.fetch(key) { env[key] }

        def temperature(env) = options.fetch(:temperature) { env.fetch(:temperature, DEFAULT_TEMPERATURE) }

        def tool_adapters(env) = Brute::Tools::Adapter.wrap_all(option(env, :tools) || [])

        # ruby_llm wants { name => tool }, which is the shape wrap_all already
        # returns; only the values need presenting as ruby_llm tools. A tool
        # written against ruby_llm goes through untouched.
        def ruby_llm_tools(env)
          tool_adapters(env).transform_values do |adapter|
            adapter.original.is_a?(::RubyLLM::Tool) ? adapter.original : Tool.new(adapter)
          end
        end

        def streaming?(env) = options.fetch(:streaming) { env[:streaming] } == true
    end
  end
end

__END__

describe "brute/completion/ruby_llm" do
  require "brute/messages"

  FakeRubyLLMClient = Class.new do
    attr_reader :calls

    def initialize(content = "mock response")
      @content = content
      @calls = []
    end

    def complete(messages, **kwargs)
      @calls << { messages: messages.dup, kwargs: kwargs }
      Brute::Message.new(role: :assistant, content: @content)
    end
  end unless defined?(FakeRubyLLMClient)

  # A completion only gets its emit from the pipeline that runs it.
  running = lambda do |completion|
    Brute::Turn::Pipeline.new.tap { |pipeline| pipeline.run completion }
  end

  it "advertises env[:tools] as ruby_llm tools" do
    client = FakeRubyLLMClient.new
    tool = {
      name:        "echo",
      description: "Echo the input back",
      params:      { msg: { type: "string", desc: "what to echo", required: true } },
      execute:     ->(msg:) { msg },
    }

    env = { messages: Brute.log, provider: :stub, model: "m", tools: [tool], events: [] }
    env[:messages].user("hi")
    Brute::Turn::Pipeline.new.tap { |p| p.run Brute::Completion::RubyLLM.new(client: client) }.call(env)

    tools = client.calls.first[:kwargs][:tools]
    tools.keys.should == [:echo]

    advertised = tools[:echo]
    advertised.name.should == "echo"
    advertised.description.should == "Echo the input back"
    advertised.params_schema[:properties][:msg][:type].should == "string"
    advertised.params_schema[:required].should == ["msg"]
    advertised.provider_params.should == {}
    advertised.call(msg: "back").should == "back"
  end

  it "completes a turn, prefers point-of-use options over env, and reports failure through the hooks" do
    client = FakeRubyLLMClient.new("hello there")
    env = { messages: Brute.log, provider: :stub, model: "env-model", tools: [], events: [] }
    env[:messages].user("hi")

    seen = []
    pipeline = running.call(Brute::Completion::RubyLLM.new(client: client, model: "use-this-model", temperature: 0.1))
    pipeline.on(Brute::Hooks::BEFORE_LLM_EVENT) { |_env| seen << :before }
    pipeline.on(Brute::Hooks::AFTER_LLM_EVENT) { |_env| seen << :after }
    pipeline.call(env)

    env[:messages].last.role.should == :assistant
    env[:messages].last.content.should == "hello there"
    seen.should == [:before, :after]

    client.calls.first[:kwargs][:model].should == "use-this-model"
    client.calls.first[:kwargs][:temperature].should == 0.1

    # Unset options fall back to env, and temperature to its default.
    fallback = FakeRubyLLMClient.new
    fallback_env = { messages: Brute.log, provider: :stub, model: "env-model", tools: [], events: [] }
    fallback_env[:messages].user("hi")
    running.call(Brute::Completion::RubyLLM.new(client: fallback)).call(fallback_env)
    fallback.calls.first[:kwargs][:model].should == "env-model"
    fallback.calls.first[:kwargs][:temperature].should == 0.7

    # A raising provider is reported, not propagated.
    boom = Object.new
    boom.define_singleton_method(:complete) { |_messages, **_kwargs| raise "no route to host" }
    failed = []
    failing = running.call(Brute::Completion::RubyLLM.new(client: boom))
    failing.on(Brute::Hooks::LLM_FAILURE_EVENT) { |_env| failed << :failure }
    failing.on(Brute::Hooks::STANDARD_ERROR_EVENT) { |_env, error| failed << error.message }

    error_env = { messages: Brute.log, provider: :stub, tools: [], events: [] }
    error_env[:messages].user("hi")
    failing.call(error_env).should.be.identical_to error_env
    failed.should == [:failure, "no route to host"]
  end
end
