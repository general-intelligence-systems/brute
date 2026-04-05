# frozen_string_literal: true

module Brute
  module Middleware
    # Handles reasoning/thinking content across model switches.
    #
    # PRE-call:
    #   - If reasoning is enabled, injects provider-specific params into
    #     the env (e.g., Anthropic thinking config, OpenAI reasoning_effort).
    #   - Tracks which model produced each message. When the model changes,
    #     strips reasoning_content from messages produced by the old model
    #     (signatures are model-specific and cryptographically tied).
    #
    # POST-call:
    #   - Records the current model on the response for future normalization.
    #
    # llm.rb exposes:
    #   - response.reasoning_content  — the thinking text
    #   - response.reasoning_tokens   — token count
    #   - Provider params pass-through — we can send thinking:, reasoning_effort:, etc.
    #
    class ReasoningNormalizer < Base
      # Effort levels that map to provider-specific params.
      # Mirrors forgecode's Effort enum.
      EFFORT_LEVELS = {
        none: "none",
        minimal: "low",
        low: "low",
        medium: "medium",
        high: "high",
        xhigh: "high",
        max: "high",
      }.freeze

      def initialize(app, model_id: nil, effort: :medium, enabled: true, budget_tokens: nil)
        super(app)
        @model_id = model_id
        @effort = effort
        @enabled = enabled
        @budget_tokens = budget_tokens
        @message_models = [] # tracks which model produced each assistant message
      end

      def call(env)
        if @enabled
          inject_reasoning_params!(env)
        end

        response = @app.call(env)

        # POST: record which model produced this response
        if response
          @message_models << @model_id
        end

        response
      end

      # Update the active model (e.g., when user switches models mid-session).
      def model_id=(new_model)
        @model_id = new_model
      end

      private

      def inject_reasoning_params!(env)
        env[:params] ||= {}
        provider = env[:provider]

        case provider_type(provider)
        when :anthropic
          if @budget_tokens
            # Older extended thinking API (claude-3.7-sonnet style)
            env[:params][:thinking] = {type: "enabled", budget_tokens: @budget_tokens}
          else
            # Newer effort-based API (claude-4 style) — pass through
            # Anthropic handles this via the model itself
          end
        when :openai
          env[:params][:reasoning_effort] = EFFORT_LEVELS[@effort] || "medium"
        end
      end

      def provider_type(provider)
        class_name = provider.class.name.to_s.downcase
        if class_name.include?("anthropic")
          :anthropic
        elsif class_name.include?("openai")
          :openai
        elsif class_name.include?("google") || class_name.include?("gemini")
          :google
        else
          :unknown
        end
      end
    end
  end
end
