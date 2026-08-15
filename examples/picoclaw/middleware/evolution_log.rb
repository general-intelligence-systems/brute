# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"
require "time"

# EvolutionLog — observe mode of picoclaw's self-evolution pipeline
# (pkg/evolution): every completed turn is appended to
# .evolution/records.jsonl as a trimmed LearningRecord. Draft/apply (turning
# repeated successful patterns into skills) is not ported — the records are
# the data it would work on.
#
# IN : notes the message count in env[:metadata][:evolution_from].
# OUT: builds the record from this turn's message delta; no-op when the
#      heartbeat gate skipped the turn (nothing happened worth learning).
#
# Side effects: appends one JSONL line per turn.
class EvolutionLog
  def initialize(app, path:)
    @app = app
    @path = path
  end

  def call(env)
    env[:metadata][:evolution_from] = env[:messages].size
    @app.call(env)
    record(env) unless env[:metadata][:heartbeat] == :skipped
    env
  end

  private

  def record(env)
    delta = env[:messages].drop(env[:metadata][:evolution_from] || 0)

    tool_names = {} # tool_call_id => name
    skills_used = []
    delta.each do |m|
      next unless m.role == :assistant && m.respond_to?(:tool_calls) && m.tool_calls

      m.tool_calls.each do |tc|
        name = tc_field(tc, :name).to_s
        tool_names[tc_field(tc, :id)] = name
        skills_used << (tc_field(tc, :arguments) || {})["name"].to_s if name == "skill"
      end
    end

    tools = delta.select { |m| m.role == :tool }.map do |m|
      {
        name: tool_names[m.tool_call_id] || "unknown",
        success: !m.content.to_s.start_with?("Error:", "Command blocked"),
      }
    end

    reply = delta.reverse.find { |m| m.role == :assistant && !m.content.to_s.strip.empty? }&.content.to_s

    append(
      id: SecureRandom.hex(8),
      kind: "task",
      created_at: Time.now.iso8601,
      tools: tools,
      skills_used: skills_used.uniq.reject(&:empty?),
      reply: reply.to_s[0, 200],
      success: tools.all? { |t| t[:success] },
    )
  end

  def append(record)
    FileUtils.mkdir_p(File.dirname(@path))
    File.open(@path, "a") { |f| f.puts(JSON.generate(record)) }
  end

  # tool_calls arrive as Brute::ToolCall (accessors) or plain Hashes.
  def tc_field(tc, key)
    tc.respond_to?(key) ? tc.public_send(key) : (tc[key] || tc[key.to_s])
  end
end
