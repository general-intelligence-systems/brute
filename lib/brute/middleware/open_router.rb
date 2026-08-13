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
          messages = Brute::MessageTransport::OpenRouter.dump_all(env[:messages])

          ::OpenRouter::Client.new(**@config).then do |client|
            client.complete(messages, @options).then do |response|

              # OpenRouter in fact only returns a single message...
              # https://github.com/estiens/open_router_enhanced/blob/main/lib/open_router/response.rb
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
