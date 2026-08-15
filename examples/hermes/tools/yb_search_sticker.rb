# frozen_string_literal: true

require "json"

# yb_search_sticker — hermes toolset: hermes-yuanbao
# Port of hermes-agent `tools/yuanbao_tools.py:654` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_yuanbao
module HermesTools
  class YbSearchSticker < Brute::Tool
    description "Search the built-in Yuanbao sticker (TIM face / 表情包) catalogue by keyword. Returns the top matching candidates with sticker_id, name, and description. Use this BEFORE yb_send_sticker to discover the right sticker_id. Sticker = 贴纸 = TIM face — NOT a message reaction. Prefer sending a sticker over bare Unicode emoji when reacting/expressing emotion."
    params({ "type" => "object", "properties" => { "query" => { "type" => "string", "description" => "Search keyword (Chinese or English, e.g. '666', '比心', 'cool', '吃瓜'). Empty string returns the first N stickers." }, "limit" => { "type" => "integer", "description" => "Max number of candidates to return (default 10, max 50)." } }, "required" => [] })
    def name = "yb_search_sticker"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "yb_search_sticker")
    end
  end
end
