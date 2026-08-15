# frozen_string_literal: true

require "json"

# spotify_playlists — hermes toolset: spotify
# Port of hermes-agent `plugins/spotify/__init__.py:59` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
module HermesTools
  class SpotifyPlaylists < Brute::Tool
    description "spotify_playlists (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "spotify_playlists"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "spotify_playlists")
    end
  end
end
