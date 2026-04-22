# frozen_string_literal: true

module Brute
  module Loop
  # Context compaction service. When the conversation grows past configurable
  # thresholds, older messages are summarized into a condensed form and the
  # original messages are dropped, keeping the context window manageable.
  #
  # Modeled after forgecode's Compactor which uses an eviction window and
  # retention window strategy.
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
      return true if usage && (usage.total_tokens || 0) > @config[:token_threshold]
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
