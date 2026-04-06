# frozen_string_literal: true

module Brute
  module Middleware
    # The terminal "app" in the pipeline — performs the actual LLM call.
    #
    # When streaming, on_content fires incrementally via AgentStream.
    # When not streaming, fires on_content post-hoc with the full text.
    #
    class LLMCall
      def call(env)
        ctx = env[:context]
        response = ctx.talk(env[:input])

        # Only fire on_content post-hoc when NOT streaming
        # (streaming delivers chunks incrementally via AgentStream)
        unless env[:streaming]
          if (cb = env.dig(:callbacks, :on_content)) && response
            text = safe_content(response)
            cb.call(text) if text
          end
        end

        response
      end

      private

      # Safely extract text content from an LLM response.
      # Returns nil when the response contains only tool calls (no assistant text),
      # which causes LLM::Contract::Completion#content to raise NoMethodError
      # because messages.find(&:assistant?) returns nil.
      def safe_content(response)
        return nil unless response.respond_to?(:content)
        response.content
      rescue NoMethodError
        nil
      end
    end
  end
end
