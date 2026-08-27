# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/hooks"

module Brute
  module Completion
    # Completion backed by the llm.rb gem (https://github.com/llmrb/llm.rb).
    #
    #   Brute.agent
    #     .use(Brute::Middleware::SystemPrompt)
    #     .run(Brute::Completion::LLMrb.new(
    #       provider:         :openai,
    #       provider_options: { key: ENV["OPENAI_API_KEY"] },
    #       model:            "gpt-4o-mini",
    #     ))
    #
    #   # or hand over a provider llm.rb has already built:
    #   run Brute::Completion::LLMrb.new(client: LLM.ollama(key: nil), model: "llama3.2:latest")
    #
    #   client:           an LLM::Provider instance (takes precedence)
    #   provider:         llm.rb constructor name (:openai, :anthropic,
    #                     :ollama, ...); falls back to env[:provider]
    #   provider_options: kwargs for that constructor, e.g. { key: "..." }
    #   model:            model id (falls back to env[:model])
    #   tools:            tools list, any shape Tools::Adapter accepts
    #   temperature:      sampling temperature (default 0.7)
    class LLMrb
      include Brute::Hooks

      DEFAULT_TEMPERATURE = 0.7

      def initialize(**options)
        # Brute depends on no LLM library: the provider gem is required here,
        # at point of use, and only for this completion.
        begin
          require "llm"
        rescue LoadError
          raise LoadError, "#{self.class} needs the 'llm.rb' gem — add `gem \"llm.rb\"` to your Gemfile."
        end

        @options = options
      end

      def call(env)
        env.emit_trace do |env|
          env.emit(LLM_START_EVENT)

          # llm.rb takes the last message as the prompt and the rest as history.
          messages = Brute::MessageTransport::LLM.dump_all(env[:messages])
          prompt = messages.pop

          response = nil
          env.emit(LLM_DURATION_EVENT) { response = client(env).complete(prompt, **params(env, messages)) }

          if (usage = Brute::MessageTransport::LLM.usage_metrics(response))
            (env[:metadata] ||= {})[:last_llm_usage] = usage
          end

          Brute::MessageTransport::LLM.wrap_each(response) do |message|
            env[:messages] << message
          end

          env.emit(LLM_END_EVENT)
        rescue => error
          env.emit(LLM_FAILURE_EVENT)

          if defined?(::Faraday::Error) && error.is_a?(::Faraday::Error)
            env.emit(FARADAY_ERROR_EVENT, error)
          else
            env.emit(STANDARD_ERROR_EVENT, error)
          end

        end
        env
      end

      private

        attr_reader :options

        def params(env, history)
          params = {
            role:        nil,
            model:       option(env, :model),
            messages:    history,
            temperature: temperature(env),
          }.compact

          functions = functions(env)
          params[:tools] = functions if functions.any?
          params
        end

        def client(env)
          options[:client] || begin
            provider = option(env, :provider) or
              raise ArgumentError, "#{self.class} needs a client: or provider: option"

            ::LLM.public_send(provider, **(options[:provider_options] || {}))
          end
        end

        # Brute tools as llm.rb functions, executed by llm.rb's own dispatch.
        def functions(env)
          Brute::Tools::Adapter.wrap_all(option(env, :tools) || []).values.map do |adapter|
            schema = adapter.to_h[:parameters]

            ::LLM.function(adapter.name) do |fn|
              fn.description adapter.description
              fn.params { schema }
              fn.define { |**args| adapter.call(args) }
            end
          end
        end

        def option(env, key) = options.fetch(key) { env[key] }

        def temperature(env) = options.fetch(:temperature) { env.fetch(:temperature, DEFAULT_TEMPERATURE) }
    end
  end
end

__END__

describe "brute/completion/llmrb" do
  require "brute/messages"

  # llm.rb's own suite drives a real provider and stubs the HTTP; the seam it
  # leaves for a caller is the provider object's #complete, which is what a
  # client: option replaces.
  FakeLLMrbClient = Class.new do
    attr_reader :calls

    def initialize(content = "via llm.rb")
      @content = content
      @calls = []
    end

    def complete(prompt, **params)
      @calls << { prompt: prompt, params: params }
      ::LLM::Message.new(:assistant, @content)
    end
  end unless defined?(FakeLLMrbClient)

  it "sends the last message as the prompt, the rest as history, and appends the reply" do
    client = FakeLLMrbClient.new("hello from llm.rb")

    env = { messages: Brute.log, provider: :stub, model: "env-model", tools: [], events: [] }
    env[:messages].user("first")
    env[:messages] << Brute::Message.new(role: :assistant, content: "earlier")
    env[:messages].user("latest")

    seen = []
    pipeline = Brute::Turn::Pipeline.new
    pipeline.run Brute::Completion::LLMrb.new(client: client, temperature: 0.1)
    pipeline.on(Brute::Hooks::LLM_START_EVENT) { |_env| seen << :before }
    pipeline.on(Brute::Hooks::LLM_END_EVENT) { |_env| seen << :after }
    pipeline.call(env)

    env[:messages].last.role.should == :assistant
    env[:messages].last.content.should == "hello from llm.rb"
    seen.should == [:before, :after]

    call = client.calls.first
    call[:prompt].content.should == "latest"
    call[:params][:messages].size.should == 2
    call[:params][:temperature].should == 0.1
    call[:params][:model].should == "env-model" # falls back to env

    # env[:tools] — what the ToolPipeline put there — becomes llm.rb functions.
    tooled = FakeLLMrbClient.new
    tool = {
      name:        "echo",
      description: "Echo the input back",
      params:      { msg: { type: "string", desc: "what to echo", required: true } },
      execute:     ->(msg:) { msg },
    }
    tools_env = { messages: Brute.log, provider: :stub, model: "m", tools: [tool], events: [] }
    tools_env[:messages].user("hi")
    Brute::Turn::Pipeline.new.tap { |p| p.run Brute::Completion::LLMrb.new(client: tooled) }.call(tools_env)

    functions = tooled.calls.first[:params][:tools]
    functions.size.should == 1
    functions.first.name.should == "echo"
    functions.first.description.should == "Echo the input back"

    # Without a client, a provider is required to build one.
    no_provider = Brute::Turn::Pipeline.new
    no_provider.run Brute::Completion::LLMrb.new
    failed = []
    no_provider.on(Brute::Hooks::STANDARD_ERROR_EVENT) { |_env, error| failed << error.class }

    bare = { messages: Brute.log, tools: [], events: [] }
    bare[:messages].user("hi")
    no_provider.call(bare)
    failed.should == [ArgumentError]
  end
end
