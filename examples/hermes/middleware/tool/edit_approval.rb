# frozen_string_literal: true

require "json"

module Hermes
  module Middleware
    module Tool
      # EditApproval — write guard for write_file/patch (before). Ports
      # hermes-agent's maybe_require_edit_approval (ACP/editor sessions route
      # writes through the approval gate; fail-closed).
      #
      # OFF by default (pass-through): hermes only gates edits in editor
      # sessions. Wire a Hermes::ApprovalGate to enable it — then write_file
      # and patch are evaluated exactly like dangerous terminal commands.
      class EditApproval
        GATED = %w[write_file patch].freeze

        def initialize(app, gate: nil, **_opts)
          @app = app
          @gate = gate
        end

        def call(env)
          if @gate && GATED.include?(env[:name].to_s)
            target = env[:arguments][:path] || env[:arguments]["path"] || env[:name]
            verdict = @gate.require_approval(target: target, reason: "edit approval required for #{env[:name]}")
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
