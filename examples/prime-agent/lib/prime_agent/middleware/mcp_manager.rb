# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # McpManager — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M13, skills S12/S13).
    #
    # Ports prime-agent `packages/coding-agent/src/core/mcp/mcp-manager.ts`
    # (+ packages/ai/src/mcp/oauth.ts): the MCP integration manager. Built-in
    # catalog (linear -> https://mcp.linear.app/mcp, notion ->
    # https://mcp.notion.com/mcp; both OAuth HTTP) overlaid by user
    # mcpServers entries; a catalog-URL override WITHOUT oauth unregisters
    # the built-in provider so official tokens never leak. OAuth 2.1:
    # discovery, RFC 7591 dynamic client registration, PKCE S256, localhost
    # callback (default port 53700, 10 candidates) or manual paste; token
    # store with refresh (30s kernel-side expiry skew). Unauthed servers hide
    # their skills from the prompt. Bridge requests: mcp.refresh (refresh +
    # rewrite auth.json under lock), mcp.config (host-authorized URL +
    # headers), mcp.begin_login.
    #
    # Fill-in: owns auth state + the bridge handlers; the kernel-side Linear/
    # Notion skills call the bridge and otherwise raise NotEnabled telling
    # the model to ask the user to log in.
    class McpManager
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end

__END__

describe "prime_agent/middleware/mcp_manager" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::McpManager.new(app).call(env)
    env[:inner].should.be.true
  end
end
