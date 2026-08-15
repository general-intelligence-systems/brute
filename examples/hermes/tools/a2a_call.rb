# frozen_string_literal: true

require "json"

# a2a_call — hermes toolset: a2a
# Port of hermes-agent `plugins/platforms/a2a/tools.py:588` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class A2aCall < Brute::Tool
    description "Send a natural-language task to a remote A2A agent and return its reply. The agent is a peer (any A2A-compliant framework), not a sub-agent you control. Pass 'context_id' from a previous reply to continue a multi-turn exchange."
    params({ "type" => "object", "properties" => { "agent" => { "type" => "string", "description" => "Configured peer name (from a2a_agents) or a full http(s):// URL." }, "message" => { "type" => "string", "description" => "The task / message to send the peer, in natural language." }, "context_id" => { "type" => "string", "description" => "Optional: context id from a prior reply, to continue the conversation." } }, "required" => ["agent", "message"] })
    def name = "a2a_call"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "a2a_call")
    end
  end
end
