# frozen_string_literal: true

require_relative "../curator"

module Hermes
  module Middleware
    # Curator — the per-invocation interval check (per-turn, before).
    # When enabled and due, runs a curator pass: backup → usage-based
    # stale/archive transitions → (optional) LLM consolidation review.
    # Best-effort: a curator failure never breaks the turn.
    class Curator
      def initialize(app, dirs: [File.join(Dir.pwd, "skills")],
                     config_path: File.join(Dir.pwd, "curator.json"),
                     review_runner: nil)
        @app = app
        @dirs = dirs
        @config_path = config_path
        @review_runner = review_runner
      end

      def call(env)
        begin
          store = env[:skill_store] || Hermes::SkillStore.new(dirs: @dirs)
          Hermes::Curator.new(store, config_path: @config_path, review_runner: @review_runner).maybe_run
        rescue StandardError
          nil
        end

        @app.call(env)
      end
    end
  end
end
