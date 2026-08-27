# frozen_string_literal: true

module Brute
  # Completion middlewares — the terminal step of an agent turn. Each one is a
  # ready-made replacement for the hand-written `run` proc: it takes
  # env[:messages], calls one provider, and appends the reply back onto the log.
  #
  #   Brute.agent
  #     .use(Brute::Middleware::SystemPrompt)
  #     .run(Brute::Completion::OpenRouter.new(model: "anthropic/claude-sonnet-4"))
  #
  # Brute still owns no LLM library: each class here requires only the gem for
  # its own provider, and only when you use it.
  module Completion
    class OpenRouter
      include Brute::Hooks

      # Anything not given here falls back to the turn env, the way the other
      # completions do it: tools from env[:tools] — the list the ToolPipeline
      # middleware puts there and executes, so a pipeline declares its tools
      # once — and the model from env[:model], which lets a middleware route a
      # turn to a different one. Options given at point of use always win.
      #
      # config:   keyword arguments for OpenRouter::Client.new
      #           (access_token:, request_timeout:, uri_base:, extra_headers:).
      #           Defaults to OpenRouter.configuration's global settings.
      # options:  keyword arguments for OpenRouter::CompletionOptions.new
      #           (model:, temperature:, tools:, ...).
      def initialize(config: {}, **options)
        # Brute depends on no LLM library: the provider gem is required here,
        # at point of use, and only for this completion.
        begin
          require "open_router"
        rescue LoadError
          raise LoadError, "#{self.class} needs the 'open_router_enhanced' gem — add `gem \"open_router_enhanced\"` to your Gemfile."
        end

        @config = config
        # CompletionOptions defaults the model to "openrouter/auto", so what
        # was actually asked for is remembered before that default hides it.
        @model_given = options.key?(:model)
        @options = ::OpenRouter::CompletionOptions.new(**options)
      end

      def call(env)
        env.emit_trace do |env|
          env.emit(LLM_START_EVENT)

          messages = Brute::MessageTransport::OpenRouter.dump_all(env[:messages])

          ::OpenRouter::Client.new(**@config).then do |client|
            response = nil
            env.emit(LLM_DURATION_EVENT) { response = client.complete(messages, options(env)) }

            response.then do |response|

              # Expose the provider's usage for downstream accounting
              # (goal budgets, autonomous limits, compaction thresholds, usage
              # attribution) — additive metadata only, normalised so a reader
              # does not have to know which provider answered.
              if (usage = Brute::MessageTransport::OpenRouter.usage_metrics(response))
                (env[:metadata] ||= {})[:last_llm_usage] = usage
              end

              # OpenRouter in fact only returns a single message...
              # https://github.com/estiens/open_router_enhanced/blob/main/lib/open_router/response.rb
              Brute::MessageTransport::OpenRouter.wrap_each(response) do |message|
                env[:messages] << message
              end
            end
          end

          env.emit(LLM_END_EVENT)
        # A provider call that raises is reported through the hooks rather than
        # up the stack: :llm_failure with the turn env, then one hook naming the
        # kind of failure. The classes are looked up defensively — the provider
        # gem is only a dependency of the app that uses this middleware.
        rescue => error
          env.emit(LLM_FAILURE_EVENT)

          if defined?(::Faraday::Error) && error.is_a?(::Faraday::Error)
            env.emit(FARADAY_ERROR_EVENT, error)

          elsif defined?(::OpenRouter::ServerError) && error.is_a?(::OpenRouter::ServerError)
            env.emit(OPEN_ROUTER_SERVER_ERROR_EVENT, error)

          else
            env.emit(STANDARD_ERROR_EVENT, error)

          end

        end
        env
      end

      private

        # Point-of-use options win; the rest fall back to the env.
        def options(env)
          overrides = {}

          unless @options.tools?
            tools = tool_definitions(env)
            if tools.any?
              overrides[:tools] = tools
            end
          end

          if !@model_given && (model = env[:model])
            overrides[:model] = model
          end

          overrides.any? ? @options.merge(**overrides) : @options
        end

        # open_router_enhanced serializes an OpenRouter::Tool or a plain Hash;
        # Adapter#to_h is already the function half of that shape.
        def tool_definitions(env)
          Brute::Tools::Adapter.wrap_all(env[:tools] || []).values.map do |adapter|
            { type: "function", function: adapter.to_h }
          end
        end
    end
  end
end

__END__

describe "brute/completion/open_router" do
  require "brute/messages"

  FakeUsageResponse = Struct.new(:usage) do
    def choices
      [{ "message" => { "role" => "assistant", "content" => "hello" } }]
    end
  end unless defined?(FakeUsageResponse)

  # A completion only gets its emit from the pipeline that runs it, so every
  # turn here goes through a builder rather than calling the object directly.
  running = lambda do |completion, &block|
    pipeline = Brute::Turn::Pipeline.new
    pipeline.run completion
    block&.call(pipeline)
    pipeline
  end

  # Run one turn against a stubbed OpenRouter::Client and hand back the env.
  with_fake_client = lambda do |completion, response|
    fake_client = Object.new
    fake_client.define_singleton_method(:complete) { |_messages, _options| response }
    original = OpenRouter::Client.method(:new)
    OpenRouter::Client.define_singleton_method(:new) { |**_config| fake_client }
    begin
      env = { messages: Brute.log }
      env[:messages].user("hi")
      running.call(completion).call(env)
      env
    ensure
      OpenRouter::Client.define_singleton_method(:new, original)
    end
  end

  it "records the provider usage into env metadata and appends the message" do
    response = FakeUsageResponse.new({ "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 })
    env = with_fake_client.call(Brute::Completion::OpenRouter.new, response)

    env[:messages].last.role.should == :assistant
    # Normalised, not the provider's raw hash.
    env[:metadata][:last_llm_usage].total.should == 15
    env[:metadata][:last_llm_usage].input.should == 10
    env[:metadata][:last_llm_usage].output.should == 5
  end

  it "leaves metadata alone when the response has no usage" do
    env = with_fake_client.call(Brute::Completion::OpenRouter.new, FakeUsageResponse.new(nil))

    env.key?(:metadata).should.be.false
  end

  it "advertises env[:tools] to the provider, and lets a tools: option win" do
    captured = []
    fake_client = Object.new
    fake_client.define_singleton_method(:complete) { |_messages, options| captured << options; FakeUsageResponse.new(nil) }
    original = OpenRouter::Client.method(:new)
    OpenRouter::Client.define_singleton_method(:new) { |**_config| fake_client }

    tool = {
      name:        "echo",
      description: "Echo the input back",
      params:      { msg: { type: "string", desc: "what to echo", required: true } },
      execute:     ->(msg:) { msg },
    }

    begin
      # The ToolPipeline puts its tools in env[:tools]; the completion
      # advertises them without being told twice.
      env = { messages: Brute.log, tools: [tool] }
      env[:messages].user("hi")
      Brute::Turn::Pipeline.new.tap { |p| p.run Brute::Completion::OpenRouter.new }.call(env)

      advertised = captured.last.tools
      advertised.size.should == 1
      advertised.first[:type].should == "function"
      advertised.first[:function][:name].should == "echo"
      advertised.first[:function][:parameters][:required].should == ["msg"]

      # An empty (or absent) env[:tools] advertises nothing.
      bare = { messages: Brute.log, tools: [] }
      bare[:messages].user("hi")
      Brute::Turn::Pipeline.new.tap { |p| p.run Brute::Completion::OpenRouter.new }.call(bare)
      captured.last.tools?.should.be.false

      # Tools given at point of use win over env[:tools].
      explicit = { type: "function", function: { name: "explicit", description: "d", parameters: { type: "object" } } }
      env2 = { messages: Brute.log, tools: [tool] }
      env2[:messages].user("hi")
      Brute::Turn::Pipeline.new.tap { |p|
        p.run Brute::Completion::OpenRouter.new(tools: [explicit])
      }.call(env2)
      captured.last.tools.should == [explicit]
    ensure
      OpenRouter::Client.define_singleton_method(:new, original)
    end
  end

  it "takes the model from env[:model], and lets a model: option win" do
    captured = []
    fake_client = Object.new
    fake_client.define_singleton_method(:complete) { |_messages, options| captured << options; FakeUsageResponse.new(nil) }
    original = OpenRouter::Client.method(:new)
    OpenRouter::Client.define_singleton_method(:new) { |**_config| fake_client }

    begin
      # A middleware that routes a turn elsewhere sets env[:model].
      env = { messages: Brute.log, model: "anthropic/claude-sonnet-4" }
      env[:messages].user("hi")
      Brute::Turn::Pipeline.new.tap { |p| p.run Brute::Completion::OpenRouter.new }.call(env)
      captured.last.model.should == "anthropic/claude-sonnet-4"

      # Given at point of use, it wins.
      env2 = { messages: Brute.log, model: "from/env" }
      env2[:messages].user("hi")
      Brute::Turn::Pipeline.new.tap { |p|
        p.run Brute::Completion::OpenRouter.new(model: "use/this")
      }.call(env2)
      captured.last.model.should == "use/this"

      # With neither, the gem's own default stands.
      bare = { messages: Brute.log }
      bare[:messages].user("hi")
      Brute::Turn::Pipeline.new.tap { |p| p.run Brute::Completion::OpenRouter.new }.call(bare)
      captured.last.model.should == "openrouter/auto"
    ensure
      OpenRouter::Client.define_singleton_method(:new, original)
    end
  end

  it "reports a failed provider call through the hooks instead of raising" do
    seen = []

    boom = RuntimeError.new("no route to host")
    fake_client = Object.new
    fake_client.define_singleton_method(:complete) { |_messages, _options| raise boom }
    original = OpenRouter::Client.method(:new)
    OpenRouter::Client.define_singleton_method(:new) { |**_config| fake_client }

    begin
      env = { messages: Brute.log }
      env[:messages].user("hi")
      pipeline = Brute::Turn::Pipeline.new
      pipeline.run Brute::Completion::OpenRouter.new
      %i[llm_failure standard_error llm_end].each do |event|
        pipeline.on(event) { |hook_env, extra| seen << [event, hook_env, extra] }
      end
      returned = pipeline.call(env)

      returned.should.be.identical_to env
      seen.map(&:first).should == [:llm_failure, :standard_error]
      seen.first[1].should.be.identical_to env
      seen.last[1].should.be.identical_to env
      seen.last[2].should.be.identical_to boom
    ensure
      OpenRouter::Client.define_singleton_method(:new, original)
    end
  end

end
