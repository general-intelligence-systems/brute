# frozen_string_literal: true

require "fileutils"
require "time"

module Hermes
  module Middleware
    # ErrorLog — the agent.log / errors.log split (per-turn, around).
    # Port of hermes-agent hermes_logging.py: turn events go to
    # logs/agent.log; anything with an error (raised or tool-error results)
    # also lands in logs/errors.log. Never breaks a turn.
    class ErrorLog
      def initialize(app, dir: File.join(Dir.pwd, "logs"))
        @app = app
        @dir = dir
      end

      def call(env)
        log_line("turn start (#{env[:messages].size} messages)")

        begin
          @app.call(env)
        rescue StandardError => e
          error_line("turn raised: #{e.class}: #{e.message}")
          raise
        end

        Array(env[:events]).each do |event|
          next unless event.is_a?(Hash)

          if event[:type] == :tool_result && event.dig(:data, :status) == "error"
            error_line("tool #{event.dig(:data, :name)}: #{event.dig(:data, :error_message) || event.dig(:data, :error_type)}")
          elsif event[:type] == :compaction
            log_line("compaction: #{event.dig(:data, :messages_after)} messages after")
          end
        end
        log_line("turn end (#{env[:should_exit] ? env[:should_exit][:reason] : 'completed'})")
        env
      end

      private

      def log_line(text)
        append("agent.log", text)
      end

      def error_line(text)
        append("errors.log", text)
        append("agent.log", "ERROR: #{text}")
      end

      def append(file, text)
        FileUtils.mkdir_p(@dir)
        File.open(File.join(@dir, file), "a") do |f|
          f.puts("[#{Time.now.utc.strftime('%Y-%m-%d %H:%M:%S')}] #{text}")
        end
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end
