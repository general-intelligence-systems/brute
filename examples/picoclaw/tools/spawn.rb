# frozen_string_literal: true

require "json"

# spawn — picoclaw `pkg/tools/spawn.go`. Async: acks immediately and the child
# runs on a thread as a critical subturn; results are injected back into the
# parent by Subturns::Drain / the end-of-turn join.
class Spawn < Brute::Tool
  description "Spawn a subagent to handle a task in the background. Use this for complex or " \
              "time-consuming tasks that can run independently. The subagent will complete the " \
              "task and report back when done."
  params({
    "type" => "object",
    "properties" => {
      "task" => { "type" => "string", "description" => "The task for subagent to complete" },
      "label" => { "type" => "string", "description" => "Optional short label for the task (for display)" },
      "agent_id" => { "type" => "string", "description" => "Optional target agent ID to delegate the task to" },
    },
    "required" => ["task"],
  })

  def initialize(registry:)
    @registry = registry
  end

  def name = "spawn"

  def execute(task: nil, label: nil, **_args)
    return "task is required" unless task.is_a?(String) && !task.empty?

    return "concurrency limit reached (could not acquire a subagent slot in 30s)" unless @registry.acquire

    record = @registry.register(Subturns::Registry::Task.new(id: @registry.next_id, label: label,
                                                             task: task, status: "running",
                                                             started_at: Time.now, reported: false))
    record.thread = Thread.new { Subturns.run_child(@registry, record) }

    label.to_s.empty? ? "Spawned subagent for task: #{task}" : "Spawned subagent '#{label}' for task: #{task}"
  rescue StandardError => e
    warn("spawn crashed: #{e.class}: #{e.message}")
    e.message
  end
end
