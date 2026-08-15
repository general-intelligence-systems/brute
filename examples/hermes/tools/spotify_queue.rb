# frozen_string_literal: true

require "json"

# spotify_queue — hermes toolset: spotify
# Port of hermes-agent `plugins/spotify/__init__.py:59` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
module HermesTools
  class SpotifyQueue < Brute::Tool
    description "Inspect the user's Spotify queue or add an item to it."
    params({ "type" => "object", "properties" => { "action" => { "type" => "string", "enum" => ["get", "add"] }, "uri" => { "type" => "string" }, "device_id" => { "type" => "string" } }, "required" => ["action"] })
    def name = "spotify_queue"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "spotify_queue")
    end
  end
end
