# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# LLM libraries for the examples. Brute itself depends on none of them —
# the terminal `run` proc of an agent pipeline is written by the user with
# whichever library they prefer. Only needed to run the matching example.
group :completions, optional: true do
	gem "openai"         # examples/openai/
	gem "anthropic"      # examples/anthropic/
end

# Chrome-over-CDP driver for examples/ports/browser-agent.
group :browser, optional: true do
	gem "ferrum"
	gem "websocket-driver", ">= 0.8.2" # DoS via malformed Host header
end

# Docs live under docs/ as a standalone Astro (Starlight) project with its own
# package.json; run `npm run dev` there. The one Ruby part is the API reference
# generator, which runs under this bundle for its `rdoc` pin — see the gemspec.
