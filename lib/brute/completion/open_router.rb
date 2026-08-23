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
      # config:   keyword arguments for OpenRouter::Client.new
      #           (access_token:, request_timeout:, uri_base:, extra_headers:).
      #           Defaults to OpenRouter.configuration's global settings.
      # options:  keyword arguments for OpenRouter::CompletionOptions.new
      #           (model:, temperature:, tools:, ...).
      def initialize(app, config: {}, **options)
        @app = app
        @config = config
        @options = ::OpenRouter::CompletionOptions.new(**options)
      end

      def call(env)
        env[:hooks]&.emit(:before_llm, env)

        messages = Brute::MessageTransport::OpenRouter.dump_all(env[:messages])

        ::OpenRouter::Client.new(**@config).then do |client|
          client.complete(messages, @options).then do |response|

            # Expose the provider's usage for downstream accounting
            # middleware (goal budgets, autonomous limits, compaction
            # thresholds, usage attribution) — additive metadata only.
            if response.respond_to?(:usage) && response.usage
              (env[:metadata] ||= {})[:last_llm_usage] = response.usage
            end

            # OpenRouter in fact only returns a single message...
            # https://github.com/estiens/open_router_enhanced/blob/main/lib/open_router/response.rb
            Brute::MessageTransport::OpenRouter.wrap_each(response) do |message|
              env[:messages] << message
            end
          end
        end

        env[:hooks]&.emit(:after_llm, env)
        env
      end
    rescue => error
      env[:hooks]&.emit(:llm_failure, env)

      case error

      in Faraday::Error => failure
        env[:hooks]&.emit(:faraday_error, failure)

      in OpenRouter::ServerError
        env[:hooks]&.emit(:open_router_server_error, error)

      else
        env[:hooks]&.emit(:standard_error, error)

      end
    end
  end
end

__END__

describe "brute/completion/open_router" do
  require "brute/messages"

  # The repo suite has no open_router gem; stub the two constants the
  # middleware touches (the transport wraps duck-typed responses fine).
  begin
    require "open_router"
  rescue LoadError
    module OpenRouter
      CompletionOptions = Class.new { def initialize(**_opts); end }
      Client = Class.new
    end
  end

  FakeUsageResponse = Struct.new(:usage) do
    def choices
      [{ "message" => { "role" => "assistant", "content" => "hello" } }]
    end
  end unless defined?(FakeUsageResponse)

  # Run one turn against a stubbed OpenRouter::Client and hand back the env.
  with_fake_client = lambda do |middleware, response|
    fake_client = Object.new
    fake_client.define_singleton_method(:complete) { |_messages, _options| response }
    original = OpenRouter::Client.method(:new)
    OpenRouter::Client.define_singleton_method(:new) { |**_config| fake_client }
    begin
      env = { messages: Brute.log }
      env[:messages].user("hi")
      middleware.call(env)
      env
    ensure
      OpenRouter::Client.define_singleton_method(:new, original)
    end
  end

  it "records the provider usage into env metadata and appends the message" do
    response = FakeUsageResponse.new({ "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 })
    env = with_fake_client.call(Brute::Completion::OpenRouter.new(->(e) { e }), response)

    env[:messages].last.role.should == :assistant
    env[:metadata][:last_llm_usage]["total_tokens"].should == 15
  end

  it "leaves metadata alone when the response has no usage" do
    env = with_fake_client.call(Brute::Completion::OpenRouter.new(->(e) { e }), FakeUsageResponse.new(nil))

    env.key?(:metadata).should.be.false
  end

  it "still answers to the deprecated Middleware::OpenRouter::Completion name" do
    deprecated = Brute::Middleware::OpenRouter::Completion.new(->(e) { e })
    deprecated.should.be.kind_of?(Brute::Completion::OpenRouter)

    env = with_fake_client.call(deprecated, FakeUsageResponse.new(nil))
    env[:messages].last.content.should == "hello"
  end
end
