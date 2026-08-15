# frozen_string_literal: true

require "json"

# project_switch — hermes toolset: project
# Port of hermes-agent `tools/project_tools.py:170` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class ProjectSwitch < Brute::Tool
    description "Switch this chat into an existing desktop Project (by name, slug, or id). Moves the session's workspace to the project's primary folder and the sidebar follows. The intentional way to move between projects, not `cd`."
    params({ "type" => "object", "properties" => { "project" => { "type" => "string", "description" => "Project name, slug, or id" } }, "required" => ["project"] })
    def name = "project_switch"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "project_switch")
    end
  end
end
