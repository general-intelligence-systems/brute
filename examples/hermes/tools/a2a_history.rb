# frozen_string_literal: true

require "json"

# a2a_history — hermes toolset: a2a
# Port of hermes-agent `plugins/platforms/a2a/tools.py:588` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class A2aHistory < Brute::Tool
    description "Recall a persisted A2A conversation transcript by context_id (survives restarts and context compaction). Use a2a_list to see known context ids."
    params({ "type" => "object", "properties" => { "context_id" => { "type" => "string", "description" => "Context id of the conversation to recall." }, "limit" => { "type" => "integer", "description" => "Max messages to return (default 50, max 200)." } }, "required" => ["context_id"] })
    def name = "a2a_history"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "a2a_history")
    end
  end
end
