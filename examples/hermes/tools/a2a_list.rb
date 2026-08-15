# frozen_string_literal: true

require "json"

# a2a_list — hermes toolset: a2a
# Port of hermes-agent `plugins/platforms/a2a/tools.py:588` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class A2aList < Brute::Tool
    description "List configured A2A peer agents, persisted A2A conversations, and metrics."
    params({ "type" => "object", "properties" => {} })
    def name = "a2a_list"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "a2a_list")
    end
  end
end
