# frozen_string_literal: true

require "json"

module Hermes
  module Middleware
    module Tool
      # ResultNormalize — the JSON-string contract (after). Port of
      # hermes-agent's registry result normalization:
      #   * non-String results are JSON-dumped
      #   * oversized {"error": …} strings are re-bounded at 2048 chars
      #     (hermes' tool_error convention, `… [truncated]` marker)
      class ResultNormalize
        MAX_ERROR_CHARS = 2_048

        def initialize(app, **_opts)
          @app = app
        end

        def call(env)
          @app.call(env)

          result = env[:result]
          unless result.is_a?(String)
            env[:result] = JSON.dump(result)
            return env
          end

          if result.length > MAX_ERROR_CHARS && result.lstrip.start_with?('{"error"')
            parsed = begin
              JSON.parse(result)
            rescue JSON::ParserError
              nil
            end
            if parsed && parsed["error"].is_a?(String) && parsed["error"].length > MAX_ERROR_CHARS
              parsed["error"] = "#{parsed["error"][0, MAX_ERROR_CHARS]}… [truncated]"
              env[:result] = JSON.dump(parsed)
            end
          end

          env
        end
      end
    end
  end
end
