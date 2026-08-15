# frozen_string_literal: true

require "json"

# subagent — picoclaw `pkg/tools/subagent.go`.
# Gate: registered under the tools.spawn gate with tools.subagent.enabled.
# Synchronous subturn: blocks until the subagent finishes; ForUser truncated
# to 500 chars, full result to the LLM. Backed by the subturns middleware.
# Scaffold: no-op handler, returns a JSON error string.
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

  def name = "subagent"

  def execute(**_args)
    JSON.dump("error" => "not implemented", "tool" => "subagent")
  end
end
