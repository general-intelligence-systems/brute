# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Checks context size after each LLM call and triggers compaction
    # when thresholds are exceeded.
    #
    # It should add a compaction event to the logs with the context token
    # total listed... this way a model that supports extra context can
    # include the compaction as well as the previous messages...
    #
    # Or an LLM that doesn't support it can just use the messages
    # that come after the compaction
    #
    class CompactionCheck
      def initialize(app, compactor: nil, system_prompt:, **compactor_opts)
        @app = app
        @compactor = compactor
        @compactor_opts = compactor_opts
        @system_prompt = system_prompt
      end

      def call(env)
        #@compactor ||= Compactor.new(env[:provider], **@compactor_opts)

        #messages = env[:messages]
        #usage = env[:metadata].dig(:tokens, :last_call)

        #if @compactor.should_compact?(messages, usage: usage)
        #  result = @compactor.compact(messages)
        #  if result
        #    summary_text, _recent = result
        #    env[:metadata][:compaction] = {
        #      messages_before: messages.size,
        #      timestamp: Time.now.iso8601,
        #    }
        #    # Replace the message history with the summary
        #    env[:messages] = [
        #      RubyLLM::Message.new(role: :system, content: @system_prompt),
        #      RubyLLM::Message.new(role: :user, content: "[Previous conversation summary]\n\n#{summary_text}"),
        #    ]
        #  end
        #end

        @app.call(env)
      end

      # Context compaction service. When the conversation grows past configurable
      # thresholds, older messages are summarized into a condensed form and the
      # original messages are dropped, keeping the context window manageable.
      class Compactor
        DEFAULTS = {
          token_threshold: 100_000,   # Compact when estimated tokens exceed this
          message_threshold: 200,     # Compact when message count exceeds this
          retention_window: 6,        # Minimum recent messages to always keep
          summary_model: nil,         # Model for summarization (uses agent's model if nil)
        }.freeze

        attr_reader :config

        def initialize(provider, **opts)
          @provider = provider
          @config = DEFAULTS.merge(opts)
        end

        # Check whether compaction should run based on current context state.
        def should_compact?(messages, usage: nil)
          return true if messages.size > @config[:message_threshold]
          return true if usage && (usage[:total] || 0) > @config[:token_threshold]
          false
        end

        # Compact the message history by summarizing older messages.
        #
        # Returns [summary_message, kept_messages] — the caller rebuilds
        # the context from these.
        def compact(messages)
          total = messages.size
          keep_count = [@config[:retention_window], total].min
          return nil if total <= keep_count

          old_messages = messages[0...(total - keep_count)]
          recent_messages = messages[(total - keep_count)..]

          summary_text = summarize(old_messages)

          [summary_text, recent_messages]
        end

        private

        def summarize(messages)
          # Build a condensed representation of the conversation for the summarizer
          conversation_text = messages.map { |m|
            role = if m.respond_to?(:role)
              m.role.to_s
            else
              "unknown"
            end
            content = if m.respond_to?(:content)
              m.content.to_s[0..1000]
            else
              m.to_s[0..1000]
            end

            # Include tool call info for assistant messages
            tool_info = ""
            if m.respond_to?(:functions) && m.functions&.any?
              calls = m.functions.map { |f| "#{f.name}(#{f.arguments.to_s[0..200]})" }
              tool_info = " [tools: #{calls.join(", ")}]"
            end

            "#{role}:#{tool_info} #{content}"
          }.join("\n---\n")

          prompt = <<~PROMPT
            Summarize this conversation history for context continuity. The summary will replace
            these messages in the context window, so include everything the agent needs to continue
            working effectively.

            Structure your summary as:
            ## Goal
            What the user asked for.

            ## Progress
            - Files read, created, or modified (list paths)
            - Commands executed and their outcomes
            - Key decisions made

            ## Current State
            Where things stand right now — what's done and what remains.

            ## Next Steps
            What should happen next based on the conversation.

            ---
            CONVERSATION:
            #{conversation_text}
          PROMPT

          model = @config[:summary_model] || "claude-sonnet-4-20250514"
          res = @provider.complete(prompt, model: model)
          res.content
        end
      end
    end
  end
end

test do
  # not implemented
end
