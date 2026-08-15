# frozen_string_literal: true

require "json"

# meet_say — hermes toolset: google_meet
# Port of hermes-agent `plugins/google_meet/__init__.py:83` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
module HermesTools
  class MeetSay < Brute::Tool
    description "meet_say (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "meet_say"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "meet_say")
    end
  end
end
