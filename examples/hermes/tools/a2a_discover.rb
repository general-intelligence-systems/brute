# frozen_string_literal: true

require "json"

# a2a_discover — hermes toolset: a2a
# Port of hermes-agent `plugins/platforms/a2a/tools.py:588` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class A2aDiscover < Brute::Tool
    description "Fetch and summarize another agent's A2A Agent Card from a URL (its name, description, capabilities, and skills). Use this to find out what a remote agent can do before calling it."
    params({ "type" => "object", "properties" => { "url" => { "type" => "string", "description" => "Base URL of the remote A2A agent, e.g. http://localhost:9999" } }, "required" => ["url"] })
    def name = "a2a_discover"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "a2a_discover")
    end
  end
end
