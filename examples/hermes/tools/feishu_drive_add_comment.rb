# frozen_string_literal: true

require "json"

# feishu_drive_add_comment — hermes toolset: feishu_drive
# Port of hermes-agent `tools/feishu_drive_tool.py:421` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_feishu
module HermesTools
  class FeishuDriveAddComment < Brute::Tool
    description "Add a new whole-document comment on a Feishu document. Use this for whole-document comments or as a fallback when reply_comment fails with code 1069302."
    params({ "type" => "object", "properties" => { "file_token" => { "type" => "string", "description" => "The document file token." }, "content" => { "type" => "string", "description" => "The comment text content (plain text only, no markdown)." }, "file_type" => { "type" => "string", "description" => "File type (default: docx).", "default" => "docx" } }, "required" => ["file_token", "content"] })
    def name = "feishu_drive_add_comment"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "feishu_drive_add_comment")
    end
  end
end
