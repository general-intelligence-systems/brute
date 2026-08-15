# frozen_string_literal: true

require "json"

# delegate_task — hermes toolset: delegation
# Port of hermes-agent `tools/delegate_tool.py:4658` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_delegate_requirements
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: DELEGATE_TASK_SCHEMA
module HermesTools
  class DelegateTask < Brute::Tool
    description "delegate_task (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "delegate_task"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "delegate_task")
    end
  end
end
