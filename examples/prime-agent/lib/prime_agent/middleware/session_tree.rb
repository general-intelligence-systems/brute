# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # SessionTree — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M9).
    #
    # Ports prime-agent's session branching (core/agent-session.ts
    # navigateTree + core/context-tree.ts): fork / clone / navigate over
    # parent-linked session entries — in-file navigation stays in the same
    # transcript, /fork starts a new one; usage sums are fork-aware (subtract
    # child attributions across ALL entries, not just the current branch).
    # The only model-visible piece is the abandoned-branch summary injected
    # at the navigation target ("The user explored a different conversation
    # branch before returning here...", maxTokens 2048), produced by
    # Middleware::Compaction's branch-summary variant.
    #
    # Fill-in: owns the entry tree + navigation. Priority: low — defer until
    # interactive/session-resume work; one-shot and scheduled runs never
    # branch.
    class SessionTree
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

describe "prime_agent/middleware/session_tree" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::SessionTree.new(app).call(env)
    env[:inner].should.be.true
  end
end
