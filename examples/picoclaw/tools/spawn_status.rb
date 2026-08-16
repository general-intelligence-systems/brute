# frozen_string_literal: true

require "json"

# spawn_status — picoclaw `pkg/tools/spawn_status.go`. Lists spawned subagents
# (sorted by creation, counts by status, results truncated to 300 runes) or
# details one when task_id is given. Channel scoping is a no-op here (single
# local conversation).
class SpawnStatus < Brute::Tool
  description "Get the status of spawned subagents. Returns a list of all subagents and their " \
              "current state (running, completed, failed, or canceled), or retrieves details " \
              "for a specific subagent task when task_id is provided. Results are scoped to the " \
              "current conversation's channel and chat ID; all tasks are listed only when no " \
              "channel/chat context is injected (e.g. direct programmatic calls via Execute)."
  params({
    "type" => "object",
    "properties" => {
      "task_id" => { "type" => "string", "description" => "Optional task ID (e.g. \"subagent-1\") to inspect a specific subagent. When omitted, all visible subagents are listed." },
    },
    "required" => [],
  })

  def initialize(registry:)
    @registry = registry
  end

  def name = "spawn_status"

  def execute(task_id: nil, **_args)
    if task_id.is_a?(String) && !task_id.empty?
      task = @registry.find(task_id)
      return "Subagent task not found: #{task_id}" unless task

      return format_task(task)
    end

    tasks = @registry.tasks.sort_by { |t| [t.started_at, t.id] }
    return "No subagents have been spawned." if tasks.empty?

    counts = tasks.group_by(&:status).transform_values(&:size)
    out = +"Subagent status report (#{tasks.size} total):\n"
    %w[running completed failed canceled].each do |status|
      n = counts[status].to_i
      out << format("  %-10s %d\n", "#{status.capitalize}:", n) if n.positive?
    end
    out << "\n"
    out << tasks.map { |t| format_task(t) }.join("\n\n")
    out
  rescue StandardError => e
    warn("spawn_status crashed: #{e.class}: #{e.message}")
    e.message
  end

  private

  def format_task(task)
    header = "[#{task.id}] status=#{task.status}"
    header += %(  label="#{task.label}") unless task.label.to_s.empty?
    header += "  created=#{task.started_at.utc.strftime("%Y-%m-%d %H:%M:%S UTC")}" if task.started_at

    out = +header
    out << "\n  task:   #{task.task}" unless task.task.to_s.empty?
    if task.result && !task.result.empty?
      chars = task.result.chars
      out << "\n  result: #{chars.size > 300 ? "#{chars.first(300).join}…" : task.result}"
    end
    out
  end
end
