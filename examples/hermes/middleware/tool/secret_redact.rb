# frozen_string_literal: true

module Hermes
  module Middleware
    module Tool
      # SecretRedact — scrub credentials from tool outputs (after). Port of
      # hermes-agent's agent.redact.redact_sensitive_text: tokens, keys,
      # bearer strings, private key blocks, .env assignments, connection
      # strings → [REDACTED]. Runs before ResultCaps (§6.12).
      class SecretRedact
        PATTERNS = [
          /sk-or-[A-Za-z0-9-]{10,}/,
          /sk-ant-[A-Za-z0-9-]{10,}/,
          /sk-[A-Za-z0-9]{20,}/,
          /AKIA[0-9A-Z]{16}/,
          /AIza[0-9A-Za-z_-]{20,}/,
          /ghp_[A-Za-z0-9]{20,}/,
          /github_pat_[A-Za-z0-9_]{20,}/,
          /xox[baprs]-[A-Za-z0-9-]{10,}/,
          /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m,
          /Bearer\s+[A-Za-z0-9._~+\/-]{16,}=*/,
          /(?i:(?:api[_-]?key|token|secret|password|credential))\s*[:=]\s*["']?[^\s"']{8,}/,
          %r{(?i:(?:postgres|mysql|mongodb|redis)://[^\s:]+:[^\s@]+@)},
        ].freeze

        def initialize(app, **_opts)
          @app = app
        end

        def call(env)
          @app.call(env)
          env[:result] = redact(env[:result]) if env[:result].is_a?(String)
          env
        end

        private

        def redact(text)
          PATTERNS.reduce(text) { |memo, re| memo.gsub(re, "[REDACTED]") }
        end
      end
    end
  end
end
