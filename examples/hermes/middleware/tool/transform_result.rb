# frozen_string_literal: true

module Hermes
  module Middleware
    module Tool
      # TransformResult — the final word before a result enters context
      # (after only; outermost after-phase). Port of hermes-agent's
      # transform_tool_result hook: the first transformer returning a String
      # wins.
      #
      # Transformers are callables ->(result_string, env) { String | nil },
      # supplied per turn via env[:result_transformers] (any middleware or
      # driver may append one).
      class TransformResult
        def initialize(app, **_opts)
          @app = app
        end

        def call(env)
          @app.call(env)

          Array(env[:result_transformers]).each do |transformer|
            replaced = transformer.call(env[:result].to_s, env)
            if replaced.is_a?(String)
              env[:result] = replaced
              break
            end
          end

          env
        end
      end
    end
  end
end
