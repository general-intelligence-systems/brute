# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # Autonomous — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M3).
    #
    # Ports prime-agent `packages/coding-agent/src/core/autonomous.ts`:
    # bounded continuations for runs with no human input. After each turn,
    # decides whether to inject a "keep working" user message: never after
    # error/abort; runs gate shell commands (exit 0 = pass); skips re-running
    # a failed gate when the git worktree snapshot (status + diff + sha256 of
    # untracked) is unchanged. Gate failure injects "Autonomous quality gate
    # failed (attempt N/M): <cmd> ... Continue working."
    # Limits: maxContinuations 3, maxTurns 12, maxTokens 80_000 (cache reads
    # excluded), timeout 30 min; gates: maxRetries 3, timeout 5 min, output
    # cap 6000 chars. RLM children are force-disabled.
    #
    # Fill-in: owns the runtime counters, gate runner and continuation
    # decision; runs AFTER Goal's continuation (goal gets first refusal).
    class Autonomous
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

describe "prime_agent/middleware/autonomous" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::Autonomous.new(app).call(env)
    env[:inner].should.be.true
  end
end
