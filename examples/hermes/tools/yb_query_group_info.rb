# frozen_string_literal: true

require "json"

# yb_query_group_info — hermes toolset: hermes-yuanbao
# Port of hermes-agent `tools/yuanbao_tools.py:502` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_yuanbao
module HermesTools
  class YbQueryGroupInfo < Brute::Tool
    description "Query basic info about a group (called '派/Pai' in the app), including group name, owner, and member count."
    params({ "type" => "object", "properties" => { "group_code" => { "type" => "string", "description" => "The unique group identifier (group_code)." } }, "required" => ["group_code"] })
    def name = "yb_query_group_info"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "yb_query_group_info")
    end
  end
end
