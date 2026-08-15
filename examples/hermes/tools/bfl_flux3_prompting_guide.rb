# frozen_string_literal: true

require "json"

# bfl_flux3_prompting_guide — hermes toolset: bfl
# Port of hermes-agent `tools/flux3_video_tool.py:1240` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_bfl_requirements
module HermesTools
  class BflFlux3PromptingGuide < Brute::Tool
    description "Read this before your first FLUX 3 generation. The prompting and grounding guide: how to research a subject so it renders as itself, how to assemble a prompt, which generate tool fits, and how to save and deliver the finished clip. Takes no arguments and spends no generation budget."
    params({ "type" => "object", "properties" => {}, "additionalProperties" => false })
    def name = "bfl_flux3_prompting_guide"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "bfl_flux3_prompting_guide")
    end
  end
end
