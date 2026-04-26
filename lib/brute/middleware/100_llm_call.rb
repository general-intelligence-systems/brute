# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Minimal struct so ruby_llm's render_payload can call model.id
    ModelRef = Struct.new(:id, :max_tokens) do
      def to_s = id.to_s
    end

    # Terminal middleware. Calls the LLM with the current conversation,
    # appends the response to the session, and fires events along the way.
    #
    # Reads from env:
    #   :provider, :model, :tools, :system_prompt, :messages, :events,
    #   :input (optional — first call of a turn), :streaming (optional),
    #   :params (optional)
    #
    # Mutates env:
    #   :messages   — appends the assistant response (and consumes :input)
    #   :should_exit — sets on error
    class LLMCall
      def call(env)
        consume_input(env)

        env[:events] << { type: :assistant_start }

        response = complete(env)
        env[:messages] << response

        # Fire on_content post-hoc when not streaming (streaming fires per-chunk)
        unless env[:streaming]
          text = response.content
          env[:events] << { type: :content, data: text } if text && !text.empty?
        end

        env[:events] << { type: :assistant_complete, data: response }

        response
      rescue => e
        handle_error(env, e)
      end

      private

      # First call of a turn has :input set; on tool-result iterations
      # the user message is already in :messages.
      def consume_input(env)
        return unless env[:input]
        env[:messages] << RubyLLM::Message.new(role: :user, content: env[:input])
        env[:input] = nil
      end

      def complete(env)
        llm = env[:provider].ruby_llm_provider
        model = ModelRef.new(env[:model] || env[:provider].default_model, 16_384)

        params      = env.fetch(:params, {}).dup
        temperature = params.delete(:temperature)
        thinking    = params.delete(:thinking)
        headers     = env[:provider].respond_to?(:extra_headers) ? env[:provider].extra_headers : {}

        kwargs = {
          tools:       build_tools_hash(env[:tools]),
          temperature: temperature,
          model:       model,
          params:      params,
          headers:     headers,
          thinking:    thinking,
        }

        if env[:streaming]
          llm.complete(build_messages(env), **kwargs) { |chunk| handle_chunk(env, chunk) }
        else
          llm.complete(build_messages(env), **kwargs)
        end
      end

      def build_messages(env)
        msgs = []
        msgs << RubyLLM::Message.new(role: :system, content: env[:system_prompt]) if env[:system_prompt]
        msgs.concat(env[:messages])
        msgs
      end

      def build_tools_hash(tools)
        return {} unless tools&.any?
        tools.each_with_object({}) do |tool, hash|
          instance = tool.is_a?(Class) ? tool.new : tool
          hash[instance.name.to_sym] = instance
        end
      end

      def handle_chunk(env, chunk)
        if chunk.content && !chunk.content.to_s.empty?
          env[:events] << { type: :content, data: chunk.content.to_s }
        end

        if chunk.respond_to?(:thinking) && chunk.thinking&.respond_to?(:text) && chunk.thinking.text
          env[:events] << { type: :reasoning, data: chunk.thinking.text }
        end
      end

      def handle_error(env, error)
        message = error.message.to_s.gsub(/\s*\n\s*/, " ").strip
      
        env[:events] << {
          type: :error,
          data: {
            error:    error,
            provider: env[:provider]&.name,
            model:    env[:model] || env[:provider]&.default_model,
            message:  message,
          }
        }
        env[:messages] << RubyLLM::Message.new(role: :system, content: message)
        env[:should_exit] = { reason: "llm_error", message: message, source: "LLMCall" }
        env[:events] << { type: :assistant_complete, data: nil }
      end
    end
  end
end
