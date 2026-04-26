# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Terminal middleware. Calls the LLM with the current conversation,
    # appends the response to the session, and fires events along the way.
    #
    class LLMCall
      def call(env)

        available_tools = env[:tools].each_with_object({}) do |tool, hash|
          instance = tool.is_a?(Class) ? tool.new : tool
          hash[instance.name.to_sym] = instance
        end

        kwargs = {
          model:       env[:model],
          tools:       available_tools,
          headers:     env[:provider]&.extra_headers || {},
          params:      params,
          temperature: env.dig(:params, :temperature),
          thinking:    env.dig(:params, :thinking),
        }


        complete(kwargs, chunk_handler).then do |response|
          env[:messages] << response
        end
      end

      private

        def complete(kwargs, chunk_handler)
          if env[:streaming] == true
            env[:provider].complete(env[:messages], **kwargs) do |chunk|
              if chunk.content && !chunk.content.to_s.empty?
                env[:events] << { type: :content, data: chunk.content.to_s }
              end

              if chunk.respond_to?(:thinking) && chunk.thinking&.respond_to?(:text) && chunk.thinking.text
                env[:events] << { type: :reasoning, data: chunk.thinking.text }
              end
            end
          else
            env[:provider].complete(env[:messages], **kwargs).then do |response|
              if response.content.present?
                env[:events] << { type: :content, data: response.content }
              end
            end
          end
        end
    end
  end
end

test do
  # not implemented
end
