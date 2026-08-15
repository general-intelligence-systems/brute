# frozen_string_literal: true

require "json"

# image_generate — hermes toolset: image_gen
# Port of hermes-agent `tools/image_generation_tool.py:1983` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_image_generation_requirements
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: IMAGE_GENERATE_SCHEMA
module HermesTools
  class ImageGenerate < Brute::Tool
    description "image_generate (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "image_generate"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "image_generate")
    end
  end
end
