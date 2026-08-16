# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"
require "time"

module Hermes
  module Middleware
    # EvolutionLog — the learning-loop audit trail (per-turn, after).
    # Observe mode: every completed turn appends a trimmed record to
    # .evolution/records.jsonl (kind, tools used, success, reply preview),
    # plus the review's actions when the learning loop fired this turn.
    # Never breaks a turn.
    class EvolutionLog
      def initialize(app, path: File.join(Dir.pwd, ".evolution", "records.jsonl"))
        @app = app
        @path = path
      end

      def call(env)
        from = env[:messages].size
        @app.call(env)
        record(env, from) unless env[:should_exit]
        env
      end

      private

      def record(env, from)
        delta = env[:messages].drop(from)

        tool_names = {}
        delta.each do |m|
          next unless m.role == :assistant && m.respond_to?(:tool_calls) && m.tool_calls

          m.tool_calls.each { |tc| tool_names[tc.id] = tc.name.to_s }
        end

        tools = delta.select { |m| m.role == :tool }.map do |m|
          {
            name: tool_names[m.tool_call_id] || "unknown",
            success: !m.content.to_s.start_with?("Error:") && !m.content.to_s.include?('"error"'),
          }
        end

        reply = delta.reverse.find { |m| m.role == :assistant && !m.content.to_s.strip.empty? }&.content.to_s

        entry = {
          id: SecureRandom.hex(8),
          kind: "task",
          at: Time.now.utc.iso8601,
          tools: tools,
          tool_count: tools.size,
          reply_preview: reply[0, 300],
          review_fired: { memory: !!env[:review_memory], skills: !!env[:review_skills] },
        }

        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") { |f| f.puts(JSON.dump(entry)) }
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end
