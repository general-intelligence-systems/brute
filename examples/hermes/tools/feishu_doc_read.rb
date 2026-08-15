# frozen_string_literal: true

require "json"

# feishu_doc_read — hermes toolset: feishu_doc
# Port of hermes-agent `tools/feishu_doc_tool.py:128` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_feishu
module HermesTools
  class FeishuDocRead < Brute::Tool
    description "Read the full content of a Feishu/Lark document as plain text. Useful when you need more context beyond the quoted text in a comment."
    params({ "type" => "object", "properties" => { "doc_token" => { "type" => "string", "description" => "The document token (from the document URL or comment context)." } }, "required" => ["doc_token"] })
    def name = "feishu_doc_read"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "feishu_doc_read")
    end
  end
end
