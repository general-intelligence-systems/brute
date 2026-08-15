# frozen_string_literal: true

require "json"

# feishu_drive_reply_comment — hermes toolset: feishu_drive
# Port of hermes-agent `tools/feishu_drive_tool.py:409` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_feishu
module HermesTools
  class FeishuDriveReplyComment < Brute::Tool
    description "Reply to a local comment thread on a Feishu document. Use this for local (quoted-text) comments. For whole-document comments, use feishu_drive_add_comment instead."
    params({ "type" => "object", "properties" => { "file_token" => { "type" => "string", "description" => "The document file token." }, "comment_id" => { "type" => "string", "description" => "The comment ID to reply to." }, "content" => { "type" => "string", "description" => "The reply text content (plain text only, no markdown)." }, "file_type" => { "type" => "string", "description" => "File type (default: docx).", "default" => "docx" } }, "required" => ["file_token", "comment_id", "content"] })
    def name = "feishu_drive_reply_comment"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "feishu_drive_reply_comment")
    end
  end
end
