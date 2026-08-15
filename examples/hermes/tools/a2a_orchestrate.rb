# frozen_string_literal: true

require "json"

# a2a_orchestrate — hermes toolset: a2a
# Port of hermes-agent `plugins/platforms/a2a/tools.py:588` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class A2aOrchestrate < Brute::Tool
    description "Fan-out a task to multiple peer agents by capability. Peers are matched from config.yaml a2a_agents.*.capabilities. Modes: 'all' (return all replies), 'first' (first successful), 'best' (longest successful reply)."
    params({ "type" => "object", "properties" => { "capability" => { "type" => "string", "description" => "Capability to match (e.g. 'research', 'code') or '*' for all peers." }, "message" => { "type" => "string", "description" => "The task to send to all matching peers." }, "mode" => { "type" => "string", "enum" => ["all", "first", "best"], "description" => "How to aggregate results. Default: 'all'." }, "context_id" => { "type" => "string", "description" => "Optional: shared context id for all peers." } }, "required" => ["capability", "message"] })
    def name = "a2a_orchestrate"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "a2a_orchestrate")
    end
  end
end
