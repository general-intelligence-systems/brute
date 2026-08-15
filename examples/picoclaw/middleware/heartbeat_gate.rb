# frozen_string_literal: true

# HeartbeatGate — picoclaw's heartbeat semantics (pkg/heartbeat/service.go).
#
# A bare run starts with the trigger message "heartbeat". The gate reads
# HEARTBEAT.md: with no user tasks it SHORT-CIRCUITS — no LLM call, no
# session write (it sits outside SessionLog) — answering HEARTBEAT_OK. With
# tasks, it replaces the trigger message with picoclaw's heartbeat prompt
# (current time + proactive instructions + file content).
#
# env writes: :metadata][:heartbeat] = :skipped | :run; :messages (see above).
# Side effects: one read-only file read.
class HeartbeatGate
  TRIGGER = "heartbeat"
  MARKER = "Add your heartbeat tasks below this line:"

  def initialize(app, workspace: Dir.pwd)
    @app = app
    @workspace = workspace
  end

  def call(env)
    return @app.call(env) unless env[:messages].last&.content.to_s.strip == TRIGGER

    content = read_heartbeat
    unless user_tasks?(content)
      env[:metadata][:heartbeat] = :skipped
      env[:messages] << Brute::Message.new(role: :assistant, content: "HEARTBEAT_OK (no tasks in HEARTBEAT.md)")
      return env
    end

    env[:metadata][:heartbeat] = :run
    env[:messages] = Brute.log.tap { |log| log.user(prompt(content)) }
    @app.call(env)
  end

  private

  def read_heartbeat
    path = File.join(@workspace, "HEARTBEAT.md")
    File.exist?(path) ? File.read(path) : nil
  end

  # Ported from picoclaw's heartbeatHasUserTasks: only non-empty, non-heading
  # lines after the tasks marker count.
  def user_tasks?(content)
    trimmed = content.to_s.strip
    return false if trimmed.empty?

    section = trimmed.include?(MARKER) ? trimmed.split(MARKER, 2).last : trimmed
    section.each_line.any? do |line|
      line = line.strip
      !line.empty? && !line.start_with?("#")
    end
  end

  # Ported from picoclaw's buildPrompt.
  def prompt(content)
    <<~PROMPT
      # Heartbeat Check

      Current time: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}

      You are a proactive AI assistant. This is a scheduled heartbeat check.
      Review the following tasks and execute any necessary actions using available skills.
      If there is nothing that requires attention, respond ONLY with: HEARTBEAT_OK

      #{content}
    PROMPT
  end
end
