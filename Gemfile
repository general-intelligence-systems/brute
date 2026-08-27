# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :completions, optional: true do
	gem "openai"
	gem "anthropic"
	gem "open_router_enhanced"
  gem "llm.rb"
end

# Chrome-over-CDP driver for examples/ports/browser-agent.
group :browser, optional: true do
	gem "ferrum"
	gem "websocket-driver", ">= 0.8.2" # DoS via malformed Host header
end
