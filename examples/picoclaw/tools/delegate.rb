# frozen_string_literal: true

require "json"

# delegate — picoclaw `pkg/tools/delegate.go`. Registered only when more than
# one agent is configured (agents.list + the default "main" agent). Runs a
# synchronous subturn in the target agent's workspace/model/tools; refuses
# self-delegation; honors the subagents allowlist.
class Delegate < Brute::Tool
  description "Delegate a task to another agent and wait for the result. Use this when another " \
              "agent is better suited to handle a specific task based on their capabilities. " \
              "The target agent runs with its own workspace, model, and tools."
  params({
    "type" => "object",
    "properties" => {
      "agent_id" => { "type" => "string", "description" => "The ID of the target agent to delegate the task to" },
      "task" => { "type" => "string", "description" => "Clear description of the task to delegate" },
    },
    "required" => %w[agent_id task],
  })

  def initialize(self_id:, spawner:, allowlist: nil)
    @self_id = self_id
    @spawner = spawner
    @allowlist = allowlist # nil = all agents; [] = none; else only these ids
  end

  def name = "delegate"

  def execute(agent_id: nil, task: nil, **_args)
    agent_id = agent_id.to_s.strip
    return "agent_id is required and must be a non-empty string" if agent_id.empty?

    task = task.to_s.strip
    return "task is required and must be a non-empty string" if task.empty?

    return "cannot delegate to self" if agent_id == @self_id
    return %(not allowed to delegate to agent "#{agent_id}") if @allowlist && !@allowlist.include?(agent_id)

    result = @spawner.call(agent_id, task)
    return %(delegation to agent "#{agent_id}" returned no result) if result.to_s.empty?

    "[Response from agent \"#{agent_id}\"]\n#{result}"
  rescue StandardError => e
    %(delegation to agent "#{agent_id}" failed: #{e.message})
  end
end
