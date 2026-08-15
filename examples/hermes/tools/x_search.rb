# frozen_string_literal: true

require "json"

# x_search — hermes toolset: x_search
# Port of hermes-agent `tools/x_search_tool.py:543` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_x_search_requirements
# hermes requires_env: XAI_API_KEY
module HermesTools
  class XSearch < Brute::Tool
    description "Search X (Twitter) posts, profiles, and threads using xAI's built-in X Search tool. Read-only discovery only: use this for current discussion, reactions, or claims on public X rather than general web pages. Do not use it to post, reply, like, DM, upload media, delete, or inspect the user's authenticated X account — those require a separate authenticated X API surface outside this tool. Available when xAI credentials are configured (SuperGrok OAuth or XAI_API_KEY)."
    params({ "type" => "object", "properties" => { "query" => { "type" => "string", "description" => "What to look up on X." }, "allowed_x_handles" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Optional list of X handles to include exclusively (max 10)." }, "excluded_x_handles" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Optional list of X handles to exclude (max 10)." }, "from_date" => { "type" => "string", "description" => "Optional start date in YYYY-MM-DD format." }, "to_date" => { "type" => "string", "description" => "Optional end date in YYYY-MM-DD format." }, "enable_image_understanding" => { "type" => "boolean", "description" => "Whether xAI should analyze images attached to matching X posts.", "default" => false }, "enable_video_understanding" => { "type" => "boolean", "description" => "Whether xAI should analyze videos attached to matching X posts.", "default" => false } }, "required" => ["query"] })
    def name = "x_search"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "x_search")
    end
  end
end
