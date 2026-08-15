# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # UsageAttribution — per-iteration middleware. SCAFFOLD: pass-through
    # no-op (FEATURES.md M18).
    #
    # Ports prime-agent's usage accounting (core/context-tree.ts
    # computeOwnAndTotalUsage + core/autonomous.ts addAutonomousUsage): per
    # assistant message, attribute token usage — "own" excludes descendant
    # attributions so summing the agent family tree never double-counts;
    # "total" includes them; child (KernelAgent) usage is attributed to the
    # parent session while remaining distinguishable. Token deltas count
    # input + output + cacheWrite (cacheRead deliberately excluded for
    # autonomous; goals count input+output only). Context utilization is
    # estimated as chars/4 over the rebuilt context and reported as a percent
    # of the model's context window (nil right after a compaction).
    #
    # Fill-in: records per-iteration usage into env[:metadata] and feeds the
    # Goal budget, Autonomous limits and a future /context tree.
    class UsageAttribution
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

describe "prime_agent/middleware/usage_attribution" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::UsageAttribution.new(app).call(env)
    env[:inner].should.be.true
  end
end
