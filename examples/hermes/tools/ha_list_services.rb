# frozen_string_literal: true

require "json"

# ha_list_services — hermes toolset: homeassistant
# Port of hermes-agent `tools/homeassistant_tool.py:498` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_ha_available
module HermesTools
  class HaListServices < Brute::Tool
    description "List available Home Assistant services (actions) for device control. Shows what actions can be performed on each device type and what parameters they accept. Use this to discover how to control devices found via ha_list_entities."
    params({ "type" => "object", "properties" => { "domain" => { "type" => "string", "description" => "Filter by domain (e.g. 'light', 'climate', 'switch'). Omit to list services for all domains." } }, "required" => [] })
    def name = "ha_list_services"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "ha_list_services")
    end
  end
end
