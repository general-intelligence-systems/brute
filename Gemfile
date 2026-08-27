# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The gems brute's own completions test against (llm.rb, open_router_enhanced)
# are development dependencies in the gemspec, like ruby_llm and langchainrb --
# repeating them in an optional group would exclude them from `bundle exec`,
# and bin/test would error on every provider that needs one.
group :completions, optional: true do
	gem "openai"
	gem "anthropic"
end

# Chrome-over-CDP driver for examples/ports/browser-agent.
group :browser, optional: true do
	gem "ferrum"
	gem "websocket-driver", ">= 0.8.2" # DoS via malformed Host header
end
