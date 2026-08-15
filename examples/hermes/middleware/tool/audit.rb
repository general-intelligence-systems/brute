# frozen_string_literal: true

require "json"

module Hermes
  module Middleware
    module Tool
      # Audit — the post_tool_call observer (around). Port of hermes-agent's
      # post_tool_call hook: emits tool_call_start before and tool_result
      # after with {name, arguments, content, duration_ms, status,
      # error_type, error_message} onto env[:events]. This is the canonical
      # tool-event emitter — Nudge's use-reset detection reads these.
      class Audit
        def initialize(app, **_opts)
          @app = app
        end

        def call(env)
          started = monotonic_ms
          env[:events] << {
            type: :tool_call_start,
            data: { name: env[:name], arguments: env[:arguments] },
          }

          @app.call(env)

          env[:events] << {
            type: :tool_result,
            data: result_payload(env, monotonic_ms - started),
          }
          env
        rescue StandardError => e
          env[:events] << {
            type: :tool_result,
            data: {
              name: env[:name], status: "error", error_type: e.class.name,
              error_message: e.message, duration_ms: monotonic_ms - started,
            },
          }
          raise
        end

        private

        def result_payload(env, duration_ms)
          content = env[:result].to_s
          status = "ok"
          error_type = nil
          begin
            parsed = JSON.parse(content)
            if parsed.is_a?(Hash) && (parsed["error"] || parsed["blocked"] || parsed["success"] == false)
              status = "error"
              error_type = "tool_error"
            end
          rescue JSON::ParserError
            nil
          end
          {
            name: env[:name], content: content, duration_ms: duration_ms,
            status: status, error_type: error_type,
          }
        end

        def monotonic_ms
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
        end
      end
    end
  end
end
