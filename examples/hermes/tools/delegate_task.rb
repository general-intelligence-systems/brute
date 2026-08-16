# frozen_string_literal: true

require "json"

module HermesTools
  # delegate_task — spawn subagents. Port of hermes-agent tools/delegate_tool.py.
  #
  # Single (goal, context) or batch (tasks: [...], parallel ≤3). Roles: leaf
  # (default — no delegate/clarify/memory/cronjob) vs orchestrator (regains
  # delegate_task; depth ≤ 1). Top-level spawns are background by default —
  # the tool returns a delegation id and the completion re-enters as a new
  # turn via the tick drain. Control: action=list|steer|stop.
  class DelegateTask < Brute::Tool
    description "Spawn isolated subagents for parallel workstreams. Single goal or batch tasks; " \
                "top-level spawns run in the background and report back on completion."
    params({
      "type" => "object",
      "properties" => {
        "goal" => { "type" => "string", "description" => "The task for a single subagent." },
        "context" => { "type" => "string", "description" => "Everything the subagent needs to know." },
        "tasks" => { "type" => "array", "items" => { "type" => "object" }, "description" => "Batch: [{goal, context, role, output_schema}]." },
        "role" => { "type" => "string", "enum" => %w[leaf orchestrator], "default" => "leaf" },
        "background" => { "type" => "boolean", "description" => "Run in background (default: true at top level)." },
        "output_schema" => { "type" => "object", "description" => "JSON Schema the summary must match (one validation retry)." },
        "action" => { "type" => "string", "enum" => %w[list steer stop] },
        "subagent_id" => { "type" => "string" },
        "message" => { "type" => "string" },
      },
      "required" => [],
    })

    def initialize(delegation: nil, run_sync: nil, main_rb: nil, depth: 0)
      @delegation = delegation
      @run_sync = run_sync  # ->(goal:, context:, role:, output_schema:) → {status:, summary:, ...}
      @main_rb = main_rb
      @depth = depth
    end

    def name = "delegate_task"

    def execute(goal: nil, context: nil, tasks: nil, role: "leaf", background: nil,
                output_schema: nil, action: nil, subagent_id: nil, message: nil, **_rest)
      return err("Delegation is unavailable in this context.") unless @delegation
      case action
      when "list"
        JSON.dump("success" => true, "delegations" => @delegation.records.values.map { |r|
          r.slice("id", "goal", "role", "status", "dispatched_at")
        })
      when "steer"
        return err("subagent_id and message are required") if subagent_id.to_s.empty? || message.to_s.empty?

        @delegation.steer(subagent_id, message)
        JSON.dump("success" => true, "steered" => subagent_id)
      when "stop"
        return err("subagent_id is required") if subagent_id.to_s.empty?

        JSON.dump("success" => true, "stopped" => @delegation.stop(subagent_id))
      when nil
        spawn(goal, context, tasks, role, background, output_schema)
      else
        err("unknown action '#{action}'. Use list|steer|stop, or pass goal/tasks to spawn.")
      end
    end

    private

    def spawn(goal, context, tasks, role, background, output_schema)
      list = tasks.is_a?(Array) && !tasks.empty? ? tasks : [{ "goal" => goal, "context" => context, "role" => role, "output_schema" => output_schema }]
      return err("goal or tasks is required") if list.any? { |t| t["goal"].to_s.empty? }
      if list.size > Hermes::Delegation::MAX_CONCURRENT_CHILDREN
        return err("batch size #{list.size} exceeds max_concurrent_children (#{Hermes::Delegation::MAX_CONCURRENT_CHILDREN})")
      end

      role = @depth >= 1 ? "leaf" : role # depth cap degrades orchestrator → leaf
      background = @depth.zero? ? (background.nil? ? true : background) : false

      if background
        ids = list.map do |t|
          @delegation.dispatch(goal: t["goal"], context: t["context"], role: t["role"] || role,
                               output_schema: t["output_schema"] || output_schema, main_rb: @main_rb)
        end
        return err("at capacity (#{Hermes::Delegation::MAX_CONCURRENT_CHILDREN} background children running)") if ids.any?(&:nil?)

        return JSON.dump(
          "status" => "dispatched", "mode" => "background", "delegation_ids" => ids,
          "note" => "Subagent running in the background. The result re-enters the conversation on completion. Do not wait or poll — just continue.",
        )
      end

      results = list.map do |t|
        @run_sync.call(goal: t["goal"], context: t["context"], role: t["role"] || role,
                       output_schema: t["output_schema"] || output_schema)
      end
      JSON.dump("results" => results)
    end

    def err(message)
      JSON.dump("success" => false, "error" => message)
    end
  end
end
