# frozen_string_literal: true

module Hermes
  module Middleware
    # MemoryProviders — the external memory provider seam (per-turn).
    # Port of hermes-agent's MemoryProvider ABC (agent/memory_provider.py).
    #
    # A provider is any object responding to:
    #   prefetch(query)        — called at turn start with the user message
    #   sync_turn(messages)    — called after the turn with its new messages
    #   shutdown               — optional cleanup
    #
    # Providers are handed in at construction (config/registry is the caller's
    # job — honcho, mem0, etc. are external). Default: none.
    class MemoryProviders
      def initialize(app, providers: [])
        @app = app
        @providers = providers
      end

      def call(env)
        env[:memory_providers] = @providers

        unless @providers.empty?
          query = env[:messages].select { |m| m.role == :user }.last&.content.to_s
          @providers.each { |p| safe { p.prefetch(query) } }
        end

        from = env[:messages].size
        @app.call(env)

        unless @providers.empty?
          delta = env[:messages].drop(from)
          @providers.each { |p| safe { p.sync_turn(delta) } }
        end

        env
      end

      private

      def safe
        yield
      rescue StandardError
        nil # a provider must never take down a turn
      end
    end
  end
end
