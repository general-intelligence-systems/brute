# frozen_string_literal: true

require "json"

# project_create — hermes toolset: project
# Port of hermes-agent `tools/project_tools.py:145` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class ProjectCreate < Brute::Tool
    description "Create a desktop Project (a named workspace) and switch this chat into it. Pass `path` to anchor it to a repo/folder — this chat's workspace moves there and the sidebar follows. Use when starting work in a new repo/folder; this is the intentional way to move the session, not `cd`."
    params({ "type" => "object", "properties" => { "name" => { "type" => "string", "description" => "Human name, e.g. 'Aurora Demo'" }, "path" => { "type" => "string", "description" => "Primary repo/folder to anchor the project to" } }, "required" => ["name"] })
    def name = "project_create"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "project_create")
    end
  end
end
