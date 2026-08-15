# frozen_string_literal: true

require "json"

# ha_call_service — hermes toolset: homeassistant
# Port of hermes-agent `tools/homeassistant_tool.py:507` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_ha_available
module HermesTools
  class HaCallService < Brute::Tool
    description "Call a Home Assistant service to control a device. Use ha_list_services to discover available services and their parameters for each domain."
    params({ "type" => "object", "properties" => { "domain" => { "type" => "string", "description" => "Service domain (e.g. 'light', 'switch', 'climate', 'cover', 'media_player', 'fan', 'scene', 'script')." }, "service" => { "type" => "string", "description" => "Service name (e.g. 'turn_on', 'turn_off', 'toggle', 'set_temperature', 'set_hvac_mode', 'open_cover', 'close_cover', 'set_volume_level')." }, "entity_id" => { "type" => "string", "description" => "Target entity ID (e.g. 'light.living_room'). Some services (like scene.turn_on) may not need this." }, "data" => { "type" => "string", "description" => "Additional service data as a JSON string. Examples: {\"brightness\": 255, \"color_name\": \"blue\"} for lights, {\"temperature\": 22, \"hvac_mode\": \"heat\"} for climate, {\"volume_level\": 0.5} for media players." } }, "required" => ["domain", "service"] })
    def name = "ha_call_service"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "ha_call_service")
    end
  end
end
