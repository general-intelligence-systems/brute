# frozen_string_literal: true

module Brute
  module Middleware
    module OpenRouter
      class Completion
        def initialize(app, config: {}, **options)
          @app = app
          @config = ::OpenRouter::Configuration.new(config)
          @options = ::OpenRouter::CompletionOptions.new(options)
        end

        def call(env)
          messages = Brute::MessageTransport::OpenRouter.dump_all(env[:messages])

          ::OpenRouter::Client.new(@config).then do |client|
            client.complete(messages, @options).then do |response|

              # OpenRouter in fact only returns a single message...
              # https://github.com/estiens/open_router_enhanced/blob/main/lib/open_router/response.rb#L66
              Brute::MessageTransport::OpenRouter.wrap_each(response) do |message|
                env[:messages] << message
              end
            end
          end

          env
        end
      end
    end
  end
end
