# frozen_string_literal: true

module Brute
  module Middleware
    # Checks context size after each LLM call and triggers compaction
    # when thresholds are exceeded.
    #
    # Runs POST-call: inspects message count and token usage from the
    # response. If compaction is needed, summarizes older messages and
    # rebuilds the context with the summary + recent messages.
    #
    class CompactionCheck < Base
      def initialize(app, compactor:, system_prompt:, tools:)
        super(app)
        @compactor = compactor
        @system_prompt = system_prompt
        @tools = tools
      end

      def call(env)
        response = @app.call(env)

        ctx = env[:context]
        messages = ctx.messages.to_a.compact
        usage = ctx.usage rescue nil

        if @compactor.should_compact?(messages, usage: usage)
          result = @compactor.compact(messages)
          if result
            summary_text, _recent = result
            rebuild_context!(env, summary_text)
            env[:metadata][:compaction] = {
              messages_before: messages.size,
              timestamp: Time.now.iso8601,
            }
          end
        end

        response
      end

      private

      def rebuild_context!(env, summary_text)
        provider = env[:provider]
        new_ctx = LLM::Context.new(provider, tools: @tools)
        prompt = new_ctx.prompt do |p|
          p.system @system_prompt
          p.user "[Previous conversation summary]\n\n#{summary_text}"
        end
        new_ctx.talk(prompt)
        env[:context] = new_ctx
      end
    end
  end
end
