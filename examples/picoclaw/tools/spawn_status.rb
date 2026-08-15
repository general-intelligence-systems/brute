# frozen_string_literal: true

require "json"

# spawn_status — picoclaw `pkg/tools/spawn_status.go`.
# Gate: tools.spawn_status.enabled (default false upstream) AND
# tools.subagent.enabled. Results scoped to the current conversation's
# channel/chat; listing sorted by creation, results truncated to 300 runes.
# Scaffold: no-op handler, returns a JSON error string.
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

  def name = "spawn_status"

  def execute(**_args)
    JSON.dump("error" => "not implemented", "tool" => "spawn_status")
  end
end
