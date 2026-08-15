# frozen_string_literal: true

require_relative "../todo_store"
require_relative "../tools/todo"

module Hermes
  module Middleware
    # Todo — per-turn task list (per hermes' agent-loop intercepted tool).
    #
    # Before: hydrate the store from prior todo tool results in history (the
    # latest write wins) and install the `todo` tool via env[:provided_tools].
    # Compaction calls env[:todo_store].format_for_injection to re-inject the
    # active list after compressing.
    class Todo
      def initialize(app)
        @app = app
      end

      def call(env)
        store = env[:todo_store] ||= Hermes::TodoStore.new
        unless store.has_items?
          # Resume hydration: latest todo write in history wins (hermes
          # hydrates from prior todo tool results; ours are identified by
          # the {"todos": ...} result shape).
          prior = env[:messages].select { |m| m.role == :tool }
                                .map(&:content)
                                .select { |c| c.to_s.start_with?('{"todos"') }
          store.hydrate(prior)
        end

        env[:provided_tools] = Array(env[:provided_tools]) << HermesTools::Todo.new(store)
        @app.call(env)
      end
    end
  end
end
