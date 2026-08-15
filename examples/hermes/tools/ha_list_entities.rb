# frozen_string_literal: true

require "json"

# ha_list_entities — hermes toolset: homeassistant
# Port of hermes-agent `tools/homeassistant_tool.py:480` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_ha_available
module HermesTools
  class HaListEntities < Brute::Tool
    description "List Home Assistant entities. Optionally filter by domain (light, switch, climate, sensor, binary_sensor, cover, fan, etc.) or by area name (living room, kitchen, bedroom, etc.)."
    params({ "type" => "object", "properties" => { "domain" => { "type" => "string", "description" => "Entity domain to filter by (e.g. 'light', 'switch', 'climate', 'sensor', 'binary_sensor', 'cover', 'fan', 'media_player'). Omit to list all entities." }, "area" => { "type" => "string", "description" => "Area/room name to filter by (e.g. 'living room', 'kitchen'). Matches against entity friendly names. Omit to list all." } }, "required" => [] })
    def name = "ha_list_entities"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "ha_list_entities")
    end
  end
end
