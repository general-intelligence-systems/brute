# frozen_string_literal: true

require "json"

# vision_analyze — hermes toolset: vision
# Port of hermes-agent `tools/vision_tools.py:1798` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_vision_requirements
module HermesTools
  class VisionAnalyze < Brute::Tool
    description "Load an image into the conversation so you can see it. Accepts a URL, local file path, or data URL. When your active model has native vision, the image is attached to your context directly and you read the pixels yourself on the next turn — call this any time the user references an image (filepath in their message, URL in tool output, screenshot from the browser, etc.). For non-vision models, falls back to an auxiliary vision model that returns a text description."
    params({ "type" => "object", "properties" => { "image_url" => { "type" => "string", "description" => "Image URL (http/https), local file path, or data: URL to load." }, "question" => { "type" => "string", "description" => "Your specific question or request about the image. Optional context the model uses on the next turn after seeing the image." }, "region" => { "type" => "array", "items" => { "type" => "integer" }, "minItems" => 4, "maxItems" => 4, "description" => "Optional [x1, y1, x2, y2] crop region in pixel coordinates of the ORIGINAL image, applied before any downscaling so the region keeps full resolution. Intended flow: load the full image first, then call again with a region to zoom into a detail (small text, UI element, fine print). Coordinates are clamped to the image bounds." } }, "required" => ["image_url", "question"] })
    def name = "vision_analyze"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "vision_analyze")
    end
  end
end
