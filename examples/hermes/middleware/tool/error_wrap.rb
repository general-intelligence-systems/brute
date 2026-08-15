# frozen_string_literal: true

require "json"

module Hermes
  module Middleware
    module Tool
      # ErrorWrap — the innermost guard (around). Port of hermes-agent's
      # top-level tool exception path (model_tools.py:743): a handler exception
      # becomes a sanitized error JSON, never a raise through the turn —
      #   * "Tool execution failed: {Class}: {message}"
      #   * XML role tags, code fences, and CDATA stripped (anti-injection)
      #   * [TOOL_ERROR] prefix, 2048-char cap
      # Audit (outside this middleware) then observes a wrapped error result,
      # never a raw exception.
      class ErrorWrap
        MAX_CHARS = 2_048

        def initialize(app, **_opts)
          @app = app
        end

        def call(env)
          @app.call(env)
        rescue StandardError => e
          env[:result] = JSON.dump(
            "error" => "[TOOL_ERROR] Tool execution failed: #{e.class}: #{sanitize(e.message)}",
          )
          env
        end

        private

        def sanitize(message)
          message.to_s
            .gsub(%r{</?(system|assistant|user|tool)[^>]*>}i, "")
            .gsub(/```/, "")
            .gsub(/<!\[CDATA\[|\]\]>/, "")
            .gsub(/`/, "")
            .strip[0, MAX_CHARS]
        end
      end
    end
  end
end
