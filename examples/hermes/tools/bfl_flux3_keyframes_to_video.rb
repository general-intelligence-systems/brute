# frozen_string_literal: true

require "json"

# bfl_flux3_keyframes_to_video — hermes toolset: bfl
# Port of hermes-agent `tools/flux3_video_tool.py:1207` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_bfl_requirements
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: KEYFRAMES_TO_VIDEO_SCHEMA
module HermesTools
  class BflFlux3KeyframesToVideo < Brute::Tool
    description "bfl_flux3_keyframes_to_video (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "bfl_flux3_keyframes_to_video"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "bfl_flux3_keyframes_to_video")
    end
  end
end
