# frozen_string_literal: true

require "json"

# project_list — hermes toolset: project
# Port of hermes-agent `tools/project_tools.py:134` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class ProjectList < Brute::Tool
    description "List the desktop Projects (named workspaces) and which one is active."
    params({ "type" => "object", "properties" => {} })
    def name = "project_list"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "project_list")
    end
  end
end
