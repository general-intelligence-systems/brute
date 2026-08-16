#!/usr/bin/env ruby
# frozen_string_literal: true

# mcp_login — connect a hosted MCP integration (linear, notion) over OAuth 2.1
# and store the credential in the shared auth.json (the same file and shape
# prime-agent itself uses, so one login serves both).
#
#   nix develop ./examples/prime-agent --command ruby examples/prime-agent/mcp_login.rb linear
#   # or from this directory:  nix develop --command ruby mcp_login.rb notion

require_relative "lib/prime_agent/mcp_oauth"

server = ARGV.first.to_s.strip
if server.empty?
  warn "usage: ruby mcp_login.rb <server>   (#{PrimeAgent::Mcp::BUILTIN_CATALOG.keys.join(", ")})"
  exit 1
end

PrimeAgent::McpOAuth.login(server)
puts "#{server} connected — credential stored under mcp:#{server} in #{PrimeAgent::Mcp.auth_path}"
