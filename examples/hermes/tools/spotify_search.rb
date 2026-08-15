# frozen_string_literal: true

require "json"

# spotify_search — hermes toolset: spotify
# Port of hermes-agent `plugins/spotify/__init__.py:59` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# NOTE: dynamic schema upstream — placeholder params; see source for the real schema.
module HermesTools
  class SpotifySearch < Brute::Tool
    description "spotify_search (hermes tool)."
    params({ "type" => "object", "properties" => {} })
    def name = "spotify_search"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "spotify_search")
    end
  end
end
