# frozen_string_literal: true

require "json"

# feishu_drive_list_comments — hermes toolset: feishu_drive
# Port of hermes-agent `tools/feishu_drive_tool.py:385` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_feishu
module HermesTools
  class FeishuDriveListComments < Brute::Tool
    description "List comments on a Feishu document. Use is_whole=true to list whole-document comments only."
    params({ "type" => "object", "properties" => { "file_token" => { "type" => "string", "description" => "The document file token." }, "file_type" => { "type" => "string", "description" => "File type (default: docx).", "default" => "docx" }, "is_whole" => { "type" => "boolean", "description" => "If true, only return whole-document comments.", "default" => false }, "page_size" => { "type" => "integer", "description" => "Number of comments per page (max 100).", "default" => 100 }, "page_token" => { "type" => "string", "description" => "Pagination token for next page." } }, "required" => ["file_token"] })
    def name = "feishu_drive_list_comments"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "feishu_drive_list_comments")
    end
  end
end
