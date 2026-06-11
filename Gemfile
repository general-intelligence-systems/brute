# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Alternative LLM backends for Brute::Middleware::Completion::*.
# Only needed when you use the matching completion middleware.
group :completions, optional: true do
	gem "llm.rb"
	gem "open_router"
	gem "langchainrb"
end

# Chrome-over-CDP driver for examples/browser_agent.
group :browser, optional: true do
	gem "ferrum"
end

group :maintenance, optional: true do
	gem "utopia-project"
	gem "bake-gem"
	gem "bake-modernize"
	gem "bake-releases"
end
