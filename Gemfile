# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# LLM libraries for the examples. Brute itself depends on none of them —
# the terminal `run` proc of an agent pipeline is written by the user with
# whichever library they prefer. Only needed to run the matching example.
group :completions, optional: true do
	gem "ruby_llm"       # examples/ruby-llm/
	gem "llm.rb"         # examples/llm-rb/
	gem "openai"         # examples/openai/
	gem "anthropic"      # examples/anthropic/
	gem "open_router_enhanced"
	gem "langchainrb"
end

# Chrome-over-CDP driver for examples/ports/browser-agent.
group :browser, optional: true do
	gem "ferrum"
end

# Docs live under docs/ as a standalone Just the Docs (Jekyll) project with its
# own Gemfile; run docs/bin/serve.sh. Nothing here builds them.
