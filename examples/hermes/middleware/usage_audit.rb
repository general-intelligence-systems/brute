# frozen_string_literal: true

require "json"
require "fileutils"

module Hermes
  module Middleware
    # UsageAudit — per-call usage audit records (per-iteration).
    # Port of hermes-agent's usage_audit.jsonl (cron/scheduler.py:4624):
    # after each LLM call, append one JSONL record with the call's usage
    # (from TokenUsage's env[:usage]) — timestamp, model, input/output/total,
    # source (provider|estimate).
    class UsageAudit
      def initialize(app, path: File.join(Dir.pwd, "sessions", "usage_audit.jsonl"))
        @app = app
        @path = path
      end

      def call(env)
        @app.call(env)

        usage = env[:usage]
        record(env, usage) if usage
        env
      end

      private

      def record(env, usage)
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") do |f|
          f.puts(JSON.dump(
            "ts" => Time.now.to_f,
            "model" => env[:model],
            "input" => usage[:input],
            "output" => usage[:output],
            "total" => usage[:total],
            "source" => usage[:source].to_s,
            "session_id" => env[:session_id],
          ))
        end
      rescue SystemCallError, IOError
        nil # audit loss must never break a call
      end
    end
  end
end
