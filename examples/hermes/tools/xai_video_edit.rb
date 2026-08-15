# frozen_string_literal: true

require "json"

# xai_video_edit — hermes toolset: video_gen
# Port of hermes-agent `tools/xai_video_tools.py:189` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_xai_video_requirements
module HermesTools
  class XaiVideoEdit < Brute::Tool
    description "Edit an existing video with xAI Imagine. This is separate from `video_generate` because video editing is provider-specific. `video_url` must be the public HTTPS MP4 URL from a prior Imagine result (`video` or `public_url` on files-cdn)."
    params({ "type" => "object", "properties" => { "prompt" => { "type" => "string", "description" => "Instruction for how xAI should modify the source video." }, "video_url" => { "type" => "string", "description" => "Public HTTPS MP4 URL of the source video — the `video` or `public_url` from a prior xAI Imagine result." }, "model" => { "type" => "string", "description" => "Optional xAI Imagine model override." } }, "required" => ["prompt", "video_url"] })
    def name = "xai_video_edit"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "xai_video_edit")
    end
  end
end
