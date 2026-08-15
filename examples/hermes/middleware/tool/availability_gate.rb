# frozen_string_literal: true

require "json"

module Hermes
  module Middleware
    module Tool
      # AvailabilityGate — unknown tools and unmet requirements (before;
      # short-circuits). Port of hermes-agent's registry availability layer
      # (check_fn + 30s TTL cache).
      #
      #   * env[:tool] is nil (the dispatcher matched nothing) → Unknown tool
      #   * a declared check fails → unavailable
      #
      # Checks: a Hash of name => requirement, where requirement is
      #   - a callable (-> { true/false })
      #   - a String/Symbol env var name that must be set
      #   - an Array of env var names (all must be set)
      # Results are cached per instance for TTL seconds (hermes: 30).
      class AvailabilityGate
        TTL = 30

        def initialize(app, checks: {}, **_opts)
          @app = app
          @checks = checks.transform_keys(&:to_s)
          @cache = {}
        end

        def call(env)
          name = env[:name].to_s
          unless env[:tool]
            env[:result] = JSON.dump("error" => "Unknown tool: #{name}")
            return env
          end

          check = @checks[name]
          if check && !available?(name, check)
            env[:result] = JSON.dump("error" => "Tool '#{name}' is unavailable (requirements not met).")
            return env
          end

          @app.call(env)
        end

        private

        def available?(name, check)
          entry = @cache[name]
          return entry[:ok] if entry && (Time.now - entry[:at]) < TTL

          ok =
            case check
            when Proc then !!check.call
            when Array then check.all? { |v| ENV[v.to_s] }
            else !!ENV[check.to_s]
            end
          @cache[name] = { ok: ok, at: Time.now }
          ok
        rescue StandardError
          false
        end
      end
    end
  end
end
