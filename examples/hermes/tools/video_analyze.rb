# frozen_string_literal: true

require "json"

# video_analyze — hermes toolset: video
# Port of hermes-agent `tools/vision_tools.py:2216` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_vision_requirements
module HermesTools
  class VideoAnalyze < Brute::Tool
    description "Analyze a video from a URL or local file path using a multimodal AI model. Sends the video to a video-capable model (e.g. Gemini) for understanding. Use this for video files — for images, use vision_analyze instead. Supports mp4, webm, mov, avi, mkv, mpeg formats. Note: large videos (>20 MB) may be slow; max ~50 MB."
    params({ "type" => "object", "properties" => { "video_url" => { "type" => "string", "description" => "Video URL (http/https) or local file path to analyze." }, "question" => { "type" => "string", "description" => "Your specific question about the video. The AI will describe what happens in the video and answer your question." } }, "required" => ["video_url", "question"] })
    def name = "video_analyze"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "video_analyze")
    end
  end
end
