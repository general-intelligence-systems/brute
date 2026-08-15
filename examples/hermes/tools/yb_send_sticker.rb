# frozen_string_literal: true

require "json"

# yb_send_sticker — hermes toolset: hermes-yuanbao
# Port of hermes-agent `tools/yuanbao_tools.py:691` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_yuanbao
module HermesTools
  class YbSendSticker < Brute::Tool
    description "Send a built-in sticker (TIMFaceElem / 贴纸表情) to the current Yuanbao chat. Call yb_search_sticker first if you don't know the sticker_id/name. Sticker = 贴纸 = TIM face — NOT a message reaction. CRITICAL: Whenever the user asks you to send a sticker / 贴纸 / 表情包, you MUST use this tool. DO NOT draw a PNG via execute_code / Pillow / matplotlib and then call send_image_file — that produces a fake 'sticker' image instead of a real TIM face and is the WRONG path. If no suitable sticker_id is known, call yb_search_sticker first. When the recent thread shows users sending stickers, prefer matching that tone by replying with a sticker instead of (or in addition to) text."
    params({ "type" => "object", "properties" => { "sticker" => { "type" => "string", "description" => "Sticker name (e.g. '六六六', '比心', 'ok') or numeric sticker_id (e.g. '278'). Empty string sends a random built-in sticker." }, "chat_id" => { "type" => "string", "description" => "Target chat. Defaults to the current session. Format: 'direct:{account_id}', 'group:{group_code}', or bare account_id." }, "reply_to" => { "type" => "string", "description" => "Optional ref_msg_id to quote-reply (group chat only)." } }, "required" => [] })
    def name = "yb_send_sticker"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "yb_send_sticker")
    end
  end
end
