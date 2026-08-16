# frozen_string_literal: true

require "json"

# subagent — picoclaw `pkg/tools/subagent.go`. Synchronous subturn: blocks
# until the child finishes; the LLM gets the full result.
class Subagent < Brute::Tool
  description "Execute a subagent task synchronously and return the result. Use this for " \
              "delegating specific tasks to an independent agent instance. Returns execution " \
              "summary to user and full details to LLM."
  params({
    "type" => "object",
    "properties" => {
      "task" => { "type" => "string", "description" => "The task for subagent to complete" },
      "label" => { "type" => "string", "description" => "Optional short label for the task (for display)" },
    },
    "required" => ["task"],
  })

  def initialize(registry:)
    @registry = registry
  end

  def name = "subagent"

  def execute(task: nil, label: nil, **_args)
    return "task is required" unless task.is_a?(String) && !task.empty?

    return "Subagent execution failed: concurrency limit reached" unless @registry.acquire

    record = @registry.register(Subturns::Registry::Task.new(id: @registry.next_id, label: label,
                                                             task: task, status: "running",
                                                             started_at: Time.now, reported: false))
    Subturns.run_child(@registry, record)
    return "Subagent execution failed: #{record.result}" if record.status == "failed"

    "Subagent task completed:\nLabel: #{label.to_s.empty? ? "(unnamed)" : label}\nResult: #{record.result}"
  rescue StandardError => e
    warn("subagent crashed: #{e.class}: #{e.message}")
    "Subagent execution failed: #{e.message}"
  end
end
