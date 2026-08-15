# frozen_string_literal: true

require "json"

# yb_query_group_members — hermes toolset: hermes-yuanbao
# Port of hermes-agent `tools/yuanbao_tools.py:528` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_yuanbao
module HermesTools
  class YbQueryGroupMembers < Brute::Tool
    description "Query members of a group (called '派/Pai' in the app). Use this tool when you need to @mention someone, find a user by name, list bots (including Yuanbao AI), or list all members. IMPORTANT: You MUST call this tool before @mentioning any user, because you need the exact nickname to construct the @mention format."
    params({ "type" => "object", "properties" => { "group_code" => { "type" => "string", "description" => "The unique group identifier (group_code)." }, "action" => { "type" => "string", "enum" => ["find", "list_bots", "list_all"], "description" => "find — search a user by name (use when you need to @mention or look up someone); list_bots — list bots and Yuanbao AI assistants; list_all — list all members." }, "name" => { "type" => "string", "description" => "User name to search (partial match, case-insensitive). Required for 'find'. Use the name the user mentioned in the conversation." }, "mention" => { "type" => "boolean", "description" => "Set to true when you need to @mention/at someone in your reply. The response will include the exact @mention format to use." } }, "required" => ["group_code", "action"] })
    def name = "yb_query_group_members"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "yb_query_group_members")
    end
  end
end
