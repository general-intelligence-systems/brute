# frozen_string_literal: true

require "set"
require_relative "../session_store"
require_relative "../tools/session_search"

module Hermes
  module Middleware
    # SessionStore — durable multi-turn persistence (per-turn).
    # Port of hermes-agent's append discipline (run_agent.py:2000):
    #
    #   Before: open/create the session row, hydrate env[:messages] from the
    #   store on a fresh turn (insertion-order, active-only), mark every
    #   loaded message persisted, then CRASH-PERSIST the current user message
    #   before the loop runs (a crash must never lose it).
    #
    #   After (ensure — every exit path): append only unstamped messages in
    #   ONE batch (idempotent markers), then close the store.
    #
    #   Also installs the session_search tool via env[:provided_tools].
    class SessionStore
      def initialize(app, path: File.join(Dir.pwd, "sessions", "state.db"),
                     session_id: "hermes", source: "cli")
        @app = app
        @path = path
        @session_id = session_id
        @source = source
        @persisted = Set.new
      end

      def call(env)
        store = Hermes::SessionStore.new(path: @path)
        env[:session_store] = store
        env[:session_id] = @session_id

        store.create_session(id: @session_id, source: @source)
        hydrate(env, store)
        crash_persist(env, store)

        env[:provided_tools] = Array(env[:provided_tools]) << HermesTools::SessionSearch.new(store)

        begin
          @app.call(env)
        ensure
          flush(env, store)
          store.close
        end
      end

      private

      # Fresh turn = only the current user message in the log. Load the prior
      # transcript before it, marking everything loaded as already-persisted.
      def hydrate(env, store)
        return unless env[:messages].size == 1 && env[:messages].first.role == :user

        history = store.get_messages(@session_id)
        return if history.empty?

        current = env[:messages].first
        env[:messages].clear
        history.each do |row|
          msg = Brute::Message.new(
            role: row[:role].to_sym,
            content: row[:content],
            tool_call_id: row[:tool_call_id],
          )
          @persisted << msg.object_id
          env[:messages] << msg
        end
        env[:messages] << current
      end

      # The current user message must survive any crash after this point.
      def crash_persist(env, store)
        current = env[:messages].last
        return unless current&.role == :user
        return if @persisted.include?(current.object_id)

        store.append_message(session_id: @session_id, role: :user, content: current.content)
        @persisted << current.object_id
      end

      def flush(env, store)
        ephemeral = Array(env[:ephemeral_messages])
        fresh = env[:messages].reject { |m| @persisted.include?(m.object_id) || ephemeral.include?(m.object_id) }
        return if fresh.empty?

        store.append_messages_batch(
          session_id: @session_id,
          messages: fresh.map { |m|
            {
              role: m.role,
              content: m.content,
              tool_call_id: m.tool_call_id,
              tool_calls: (m.respond_to?(:tool_calls) && m.tool_calls&.map(&:to_h)),
            }
          },
        )
        fresh.each { |m| @persisted << m.object_id }
      rescue StandardError
        nil # persistence failure must never take the turn down with it
      end
    end
  end
end
