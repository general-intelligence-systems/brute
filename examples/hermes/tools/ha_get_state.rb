# frozen_string_literal: true

require "json"

# ha_get_state — hermes toolset: homeassistant
# Port of hermes-agent `tools/homeassistant_tool.py:489` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: _check_ha_available
module HermesTools
  class HaGetState < Brute::Tool
    description "Get the detailed state of a single Home Assistant entity, including all attributes (brightness, color, temperature setpoint, sensor readings, etc.)."
    params({ "type" => "object", "properties" => { "entity_id" => { "type" => "string", "description" => "The entity ID to query (e.g. 'light.living_room', 'climate.thermostat', 'sensor.temperature')." } }, "required" => ["entity_id"] })
    def name = "ha_get_state"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "ha_get_state")
    end
  end
end
