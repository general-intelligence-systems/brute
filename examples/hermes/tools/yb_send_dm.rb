# frozen_string_literal: true

require "json"

# yb_send_dm — hermes toolset: hermes-yuanbao
# Port of hermes-agent `tools/yuanbao_tools.py:580` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_yuanbao
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
#   schema src: {'name': 'yb_send_dm', 'description': 'Send a private/direct message (DM) to a user in a group, with optional 
#   schema src: media files. This tool automatically looks up the user by name in the group member list and sends the message.
#   schema src:  Use this when someone asks to privately message / 私信 / DM a user. Supports text, images, and file attachments
module HermesTools
  class YbSendDm < Brute::Tool
    description "yb_send_dm (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "yb_send_dm"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "yb_send_dm")
    end
  end
end
