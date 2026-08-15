# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Hermes
  module Middleware
    module Tool
      # ResultCaps — per-tool result budgets (after). Port of hermes-agent's
      # max_result_size_chars + terminal spill: oversized results are truncated
      # 40/60 head/tail with an explicit marker, and the full output spills to
      # a file the model can read on demand.
      class ResultCaps
        DEFAULT_CAP = 50_000
        CAPS = {
          "terminal" => 100_000,
          "execute_code" => 100_000,
        }.freeze

        def initialize(app, spill_dir: File.join(Dir.pwd, "sessions", "spills"), **_opts)
          @app = app
          @spill_dir = spill_dir
        end

        def call(env)
          @app.call(env)

          result = env[:result]
          return env unless result.is_a?(String)

          cap = CAPS.fetch(env[:name].to_s, DEFAULT_CAP)
          return env if result.length <= cap

          env[:result] = truncate_with_spill(result, cap, env)
          env
        end

        private

        def truncate_with_spill(content, cap, env)
          spill_path = spill(content, env)
          head = content[0, (cap * 0.4).to_i]
          tail = content[-(cap * 0.6).to_i..]
          "#{head}\n\n[... #{content.length - head.length - tail.length} chars truncated" \
          "#{spill_path ? " — full output at #{spill_path}" : ""} ...]\n\n#{tail}"
        end

        def spill(content, env)
          FileUtils.mkdir_p(@spill_dir)
          path = File.join(@spill_dir, "#{env[:name]}-#{SecureRandom.hex(4)}.log")
          File.write(path, content, encoding: Encoding::UTF_8)
          path
        rescue SystemCallError, IOError
          nil
        end
      end
    end
  end
end
