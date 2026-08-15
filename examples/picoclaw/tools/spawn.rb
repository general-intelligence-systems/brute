# frozen_string_literal: true

require "json"

# spawn — picoclaw `pkg/tools/spawn.go`.
# Gate: tools.spawn.enabled AND tools.subagent.enabled (both default true).
# Async: immediate ack, the subagent runs as a critical subturn (survives the
# parent turn) and its result is delivered back into the parent. agent_id
# checked against the per-agent subagent allowlist. Backed by the subturns
# middleware (depth <= 3, concurrency <= 5, 5-min timeout).
# Scaffold: no-op handler, returns a JSON error string.
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

  def name = "spawn"

  def execute(**_args)
    JSON.dump("error" => "not implemented", "tool" => "spawn")
  end
end
