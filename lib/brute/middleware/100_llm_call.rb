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
          instance = instance.to_ruby_llm if instance.respond_to?(:to_ruby_llm)
          hash[instance.name.to_sym] = instance
        end

        completion_options = {
          model: RubyLLM.models.find(env[:model], env[:provider]),
          tools: available_tools,
          temperature: env.fetch(:temperature, 0.7),
        }

        complete(completion_options, env).then do |response|
          env[:messages] << response
        end

        env
      end

      private

        def complete(kwargs, env)
          provider_client = RubyLLM::Provider.resolve(env[:provider]).new(Brute.config)

          if env[:streaming] == true
            provider_client.complete(env[:messages], **kwargs) do |chunk|
              if chunk.content && !chunk.content.to_s.empty?
                env[:events] << { type: :content, data: chunk.content.to_s }
              end

              if chunk.respond_to?(:thinking) && chunk.thinking&.respond_to?(:text) && chunk.thinking.text
                env[:events] << { type: :reasoning, data: chunk.thinking.text }
              end
            end
          else
            provider_client.complete(env[:messages], **kwargs).then do |response|
              if response.content.present?
                env[:events] << { type: :content, data: response.content }
              end
              response
            end
          end
        end
    end
  end
end

test do
  # not implemented
end
