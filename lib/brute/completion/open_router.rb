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
        @options = ::OpenRouter::CompletionOptions.new(**options)
      end

      def call(env)
        emit(BEFORE_LLM_EVENT, env)

        messages = Brute::MessageTransport::OpenRouter.dump_all(env[:messages])

        ::OpenRouter::Client.new(**@config).then do |client|
          response = nil
          emit(LLM_DURATION_EVENT, env) { response = client.complete(messages, @options) }

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

        emit(AFTER_LLM_EVENT, env)
        env
      # A provider call that raises is reported through the hooks rather than
      # up the stack: :llm_failure with the turn env, then one hook naming the
      # kind of failure. The classes are looked up defensively — the provider
      # gem is only a dependency of the app that uses this middleware.
      rescue => error
        emit(LLM_FAILURE_EVENT, env)

        if defined?(::Faraday::Error) && error.is_a?(::Faraday::Error)
          emit(FARADAY_ERROR_EVENT, env, error)

        elsif defined?(::OpenRouter::ServerError) && error.is_a?(::OpenRouter::ServerError)
          emit(OPEN_ROUTER_SERVER_ERROR_EVENT, env, error)

        else
          emit(STANDARD_ERROR_EVENT, env, error)

        end

        env
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
      %i[llm_failure standard_error after_llm].each do |event|
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
