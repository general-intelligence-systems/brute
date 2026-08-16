# frozen_string_literal: true

module Hermes
  module Middleware
    # ContextEngine — the pluggable context-engine seam (per-turn, before
    # PromptTiers). Port of hermes-agent agent/context_engine.py's slot.
    #
    # An engine is a callable ->(env) { [String, ...] } returning extra
    # context sections, which PromptTiers renders in the context tier
    # (env[:metadata][:context_sections]). PromptTiers itself is the built-in
    # engine; this is the slot where an external engine attaches.
    class ContextEngine
      def initialize(app, engine: nil)
        @app = app
        @engine = engine
      end

      def call(env)
        if @engine
          sections = begin
            @engine.call(env)
          rescue StandardError
            nil # an engine failure must never block the prompt
          end
          if sections.is_a?(Array) && sections.any?
            env[:metadata] ||= {}
            env[:metadata][:context_sections] = sections
          end
        end

        @app.call(env)
      end
    end
  end
end
