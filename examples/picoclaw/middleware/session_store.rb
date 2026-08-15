# frozen_string_literal: true

require "json"
require "fileutils"

# SessionStore — picoclaw's session persistence port (pkg/session/,
# pkg/memory/jsonl.go, sanitize-on-load pkg/agent/context.go:1023-1201).
# Replaces Brute::Middleware::SessionLog in the stack (this middleware
# absorbs it, per FEATURES.md §2.2).
#
# IN : if the JSONL log exists, its messages are SANITIZED (below) and
#      prepended to env[:messages]; env[:metadata][:session][:restore_point]
#      records the pre-turn message count for hard-abort rollback
#      (SteeringLoop consumes it).
# OUT: the whole message list is persisted (skipping :system — the prompt is
#      rebuilt every turn). A rollback that truncated env[:messages] persists
#      the truncated state, like picoclaw's session restore on hard abort.
#
# Sanitizer (sanitizeHistoryForProvider port): drop system messages; drop
# orphaned tool messages (no preceding assistant-with-tool-calls); drop
# assistant tool-call turns at history start or after a non-user/non-tool
# message; then require every assistant tool-call block to be followed by
# exactly matching, non-duplicate, known tool results — otherwise the whole
# block is dropped.
class SessionStore
  def initialize(app, path:, **_opts)
    @app = app
    @path = path
  end

  def call(env)
    if File.exist?(@path)
      loaded = []
      File.foreach(@path) do |line|
        line = line.strip
        loaded << Brute::Message.new(**JSON.parse(line, symbolize_names: true)) unless line.empty?
      end
      env[:messages].unshift(*sanitize(loaded))
    end

    env[:metadata][:session] = { restore_point: env[:messages].size }

    @app.call(env)

    persist(env[:messages])
    env
  end

  # Roll back env to the pre-turn restore point (hard abort port).
  def self.rollback!(env)
    point = env.dig(:metadata, :session, :restore_point)
    env[:messages] = env[:messages].first(point) if point
  end

  private

  def persist(messages)
    FileUtils.mkdir_p(File.dirname(@path))
    tmp = "#{@path}.tmp"
    File.open(tmp, "w") do |f|
      messages.each do |message|
        next if message.role.to_sym == :system

        f.puts(JSON.generate(message.to_h))
      end
    end
    File.rename(tmp, @path)
  end

  def sanitize(history)
    # Pass 1: role/alternation hygiene.
    sanitized = []
    history.each do |msg|
      case msg.role.to_sym
      when :system
        next
      when :tool
        next if sanitized.empty?

        found = false
        (sanitized.size - 1).downto(0) do |i|
          next if sanitized[i].role.to_sym == :tool

          found = sanitized[i].role.to_sym == :assistant && sanitized[i].tool_call?
          break
        end
        next unless found

        sanitized << msg
      when :assistant
        if msg.tool_call?
          next if sanitized.empty?

          prev_role = sanitized.last.role.to_sym
          next unless %i[user tool].include?(prev_role)
        end
        sanitized << msg
      else
        sanitized << msg
      end
    end

    # Pass 2: every assistant tool-call block must be followed by matching,
    # known, non-duplicate tool results — else the whole block is dropped.
    final = []
    i = 0
    while i < sanitized.size
      msg = sanitized[i]
      if msg.role.to_sym == :assistant && msg.tool_call?
        expected = {}
        invalid = false
        msg.tool_calls.each do |tc|
          if tc.id.to_s.empty?
            invalid = true
          else
            expected[tc.id] = false
          end
        end

        block = []
        seen = {}
        j = i + 1
        while j < sanitized.size && sanitized[j].role.to_sym == :tool
          candidate = sanitized[j]
          j += 1
          next if candidate.tool_call_id.to_s.empty?
          next unless expected.key?(candidate.tool_call_id)
          next if seen[candidate.tool_call_id]

          seen[candidate.tool_call_id] = true
          expected[candidate.tool_call_id] = true
          block << candidate
        end

        if !invalid && expected.values.all?
          final << msg
          final.concat(block)
        end
        i = j
        next
      end

      final << msg unless msg.role.to_sym == :tool
      i += 1
    end
    final
  end
end
