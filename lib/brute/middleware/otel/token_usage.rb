# frozen_string_literal: true

module Brute
  module Middleware
    module OTel
      # Records token usage from the LLM response as span attributes.
      #
      # Runs POST-call: reads token counts from the response usage object
      # and sets them as attributes on the span.
      #
      class TokenUsage < Base
        def call(env)
          response = @app.call(env)

          span = env[:span]
          if span && response.respond_to?(:usage) && (usage = response.usage)
            span.set_attribute("gen_ai.usage.input_tokens", usage.input_tokens.to_i)
            span.set_attribute("gen_ai.usage.output_tokens", usage.output_tokens.to_i)
            span.set_attribute("gen_ai.usage.total_tokens", usage.total_tokens.to_i)

            reasoning = usage.reasoning_tokens.to_i
            span.set_attribute("gen_ai.usage.reasoning_tokens", reasoning) if reasoning > 0
          end

          response
        end
      end
    end
  end
end
