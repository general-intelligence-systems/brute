# frozen_string_literal: true

module Brute
  module Middleware
    module OpenRouter
      class Completion
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
      end
    end
  end
end

__END__

describe "brute/middleware/open_router" do
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
  end

  it "records the provider usage into env metadata and appends the message" do
    response = FakeUsageResponse.new({ "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 })
    fake_client = Object.new
    fake_client.define_singleton_method(:complete) { |_messages, _options| response }
    original = OpenRouter::Client.method(:new)
    OpenRouter::Client.define_singleton_method(:new) { |**_config| fake_client }
    begin
      middleware = Brute::Middleware::OpenRouter::Completion.new(->(env) { env })
      env = { messages: Brute.log }
      env[:messages].user("hi")
      middleware.call(env)

      env[:messages].last.role.should == :assistant
      env[:metadata][:last_llm_usage]["total_tokens"].should == 15
    ensure
      OpenRouter::Client.define_singleton_method(:new, original)
    end
  end

  it "leaves metadata alone when the response has no usage" do
    response = FakeUsageResponse.new(nil)
    fake_client = Object.new
    fake_client.define_singleton_method(:complete) { |_messages, _options| response }
    original = OpenRouter::Client.method(:new)
    OpenRouter::Client.define_singleton_method(:new) { |**_config| fake_client }
    begin
      middleware = Brute::Middleware::OpenRouter::Completion.new(->(env) { env })
      env = { messages: Brute.log }
      env[:messages].user("hi")
      middleware.call(env)

      env.key?(:metadata).should.be.false
    ensure
      OpenRouter::Client.define_singleton_method(:new, original)
    end
  end
end
