# frozen_string_literal: true

require "json"

# feishu_drive_list_comment_replies — hermes toolset: feishu_drive
# Port of hermes-agent `tools/feishu_drive_tool.py:397` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_feishu
module HermesTools
  class FeishuDriveListCommentReplies < Brute::Tool
    description "List all replies in a comment thread on a Feishu document."
    params({ "type" => "object", "properties" => { "file_token" => { "type" => "string", "description" => "The document file token." }, "comment_id" => { "type" => "string", "description" => "The comment ID to list replies for." }, "file_type" => { "type" => "string", "description" => "File type (default: docx).", "default" => "docx" }, "page_size" => { "type" => "integer", "description" => "Number of replies per page (max 100).", "default" => 100 }, "page_token" => { "type" => "string", "description" => "Pagination token for next page." } }, "required" => ["file_token", "comment_id"] })
    def name = "feishu_drive_list_comment_replies"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "feishu_drive_list_comment_replies")
    end
  end
end
