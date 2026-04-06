# frozen_string_literal: true

module Brute
  module Middleware
    # Records every LLM exchange into a MessageStore in the OpenCode
    # {info, parts} format so sessions can be viewed later.
    #
    # Lifecycle per pipeline call:
    #
    #   1. PRE-CALL  — if this is the first call of a turn (env[:tool_results]
    #      is nil), record the user message.
    #   2. POST-CALL — record the assistant message: text content as a "text"
    #      part, each tool call as a "tool" part in "running" state.
    #   3. When the pipeline is called again with tool results, update the
    #      corresponding tool parts to "completed" (or "error").
    #
    # The middleware also stores itself in env[:message_tracking] so the
    # orchestrator can access the current assistant message ID for callbacks.
    #
    class MessageTracking < Base
      attr_reader :store

      def initialize(app, store:)
        super(app)
        @store = store
        @current_user_id = nil
        @current_assistant_id = nil
      end

      def call(env)
        env[:message_tracking] = self

        # ── Pre-call: record user message or update tool results ──
        if env[:tool_results].nil?
          # New turn — record the user message
          record_user_message(env)
        else
          # Tool results coming back — complete the tool parts
          complete_tool_parts(env)
        end

        # ── LLM call ──
        response = @app.call(env)

        # ── Post-call: record assistant message ──
        record_assistant_message(env, response)

        response
      end

      # The current assistant message ID (used by external callbacks).
      def current_assistant_id
        @current_assistant_id
      end

      private

      # ── User message ───────────────────────────────────────────────

      def record_user_message(env)
        text = extract_user_text(env)
        return unless text

        @current_user_id = @store.append_user(text: text)
      end

      def extract_user_text(env)
        input = env[:input]
        case input
        when String
          input
        when Array
          # llm.rb prompt format: array of message hashes
          user_msg = input.reverse_each.find { |m| m.respond_to?(:role) && m.role.to_s == "user" }
          user_msg&.content.to_s if user_msg
        else
          # Could be a prompt object — try to extract user content
          if input.respond_to?(:messages)
            msgs = input.messages.to_a
            user_msg = msgs.reverse_each.find { |m| m.role.to_s == "user" }
            user_msg&.content.to_s if user_msg
          end
        end
      end

      # ── Assistant message ──────────────────────────────────────────

      def record_assistant_message(env, response)
        provider_name = env[:provider]&.class&.name&.split("::")&.last&.downcase
        model_name = env[:provider]&.respond_to?(:default_model) ? env[:provider].default_model.to_s : nil

        @current_assistant_id = @store.append_assistant(
          parent_id: @current_user_id,
          model_id: model_name,
          provider_id: provider_name,
        )

        # Text content
        text = safe_content(response)
        @store.add_text_part(message_id: @current_assistant_id, text: text) if text && !text.empty?

        # Tool calls
        record_tool_calls(env)

        # Token usage
        tokens = extract_tokens(env, response)
        @store.complete_assistant(message_id: @current_assistant_id, tokens: tokens) if tokens

        # Step finish
        @store.add_step_finish(message_id: @current_assistant_id, tokens: tokens)
      end

      def record_tool_calls(env)
        ctx = env[:context]
        functions = ctx.functions
        return if functions.nil? || functions.empty?

        functions.each do |fn|
          @store.add_tool_part(
            message_id: @current_assistant_id,
            tool: fn.name,
            call_id: fn.id,
            input: fn.arguments,
          )
        end
      end

      # ── Tool results ───────────────────────────────────────────────

      def complete_tool_parts(env)
        return unless @current_assistant_id

        results = env[:tool_results]
        return unless results.is_a?(Array)

        results.each do |name, value|
          # Find the tool part by name (tool results come as [name, value] pairs)
          msg = @store.message(@current_assistant_id)
          next unless msg

          # Match by tool name — find the first running tool part with this name
          part = msg[:parts]&.find do |p|
            p[:type] == "tool" && p[:tool] == name && p.dig(:state, :status) == "running"
          end
          next unless part

          call_id = part[:callID]
          if value.is_a?(Hash) && value[:error]
            @store.error_tool_part(
              message_id: @current_assistant_id,
              call_id: call_id,
              error: value[:error],
            )
          else
            output = value.is_a?(String) ? value : value.to_s
            @store.complete_tool_part(
              message_id: @current_assistant_id,
              call_id: call_id,
              output: output,
            )
          end
        end
      end

      # ── Helpers ────────────────────────────────────────────────────

      def safe_content(response)
        return nil unless response.respond_to?(:content)
        response.content
      rescue NoMethodError
        nil
      end

      def extract_tokens(env, response)
        # Prefer the metadata accumulated by TokenTracking middleware
        meta_tokens = env.dig(:metadata, :tokens, :last_call)
        if meta_tokens
          {
            input: meta_tokens[:input] || 0,
            output: meta_tokens[:output] || 0,
            reasoning: 0,
            cache: { read: 0, write: 0 },
          }
        elsif response.respond_to?(:usage) && (usage = response.usage)
          {
            input: usage.input_tokens.to_i,
            output: usage.output_tokens.to_i,
            reasoning: usage.reasoning_tokens.to_i,
            cache: { read: 0, write: 0 },
          }
        end
      end
    end
  end
end
