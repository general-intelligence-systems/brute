# frozen_string_literal: true

require "json"

# execute_code — hermes toolset: code_execution
# Port of hermes-agent `tools/code_execution_tool.py:2197` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_sandbox_requirements
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: EXECUTE_CODE_SCHEMA
module HermesTools
  class ExecuteCode < Brute::Tool
    description "execute_code (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "execute_code"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "execute_code")
    end
  end
end
