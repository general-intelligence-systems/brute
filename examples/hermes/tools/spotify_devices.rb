# frozen_string_literal: true

require "json"

# spotify_devices — hermes toolset: spotify
# Port of hermes-agent `plugins/spotify/__init__.py:59` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class SpotifyDevices < Brute::Tool
    description "List Spotify Connect devices or transfer playback to a different device."
    params({ "type" => "object", "properties" => { "action" => { "type" => "string", "enum" => ["list", "transfer"] }, "device_id" => { "type" => "string" }, "play" => { "type" => "boolean" } }, "required" => ["action"] })
    def name = "spotify_devices"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "spotify_devices")
    end
  end
end
