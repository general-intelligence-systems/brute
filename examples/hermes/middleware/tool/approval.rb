# frozen_string_literal: true

require "json"
require_relative "../../approval_gate"

module Hermes
  module Middleware
    module Tool
      # Approval — the layered human gate (before; short-circuits).
      # Ports hermes-agent tools/approval.py: dangerous tool calls are
      # evaluated by Hermes::ApprovalGate; on deny the middleware never calls
      # inner and sets env[:result] to the BLOCKED JSON — and the denial is
      # still Audited on the unwind (§4.5, §6.11 of MIDDLEWARE.md).
      #
      # Gated tools: terminal (commands), write_file/patch (paths),
      # execute_code (code). Everything else passes through untouched.
      class Approval
        GATED_TOOLS = %w[terminal write_file patch execute_code].freeze

        def initialize(app, gate: nil, **_opts)
          @app = app
          @gate = gate || Hermes::ApprovalGate.new
        end

        def call(env)
          if GATED_TOOLS.include?(env[:name])
            verdict = @gate.evaluate(tool: env[:name], arguments: env[:arguments])
            unless verdict[:allow]
              env[:result] = JSON.dump(
                "error" => verdict[:message],
                "blocked" => true,
                "tool" => env[:name],
              )
              return env
            end
          end

          @app.call(env)
        end
      end
    end
  end
end
