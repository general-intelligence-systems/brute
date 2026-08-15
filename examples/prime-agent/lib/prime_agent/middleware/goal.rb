# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # Goal — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M2, skill S8).
    #
    # Ports prime-agent `packages/coding-agent/src/core/goals.ts`: the
    # persistent thread goal — a durable objective re-injected after EVERY
    # assistant turn until the model marks it complete from the kernel.
    # State machine: idle -> active -> paused | budget_limited | complete |
    # error. Continuation message is <goal_context>...</goal_context>
    # (status, tokens used, budget remaining, anti-premature-completion
    # instructions; objective XML-escaped as untrusted data) flattened to a
    # user message; runs BEFORE the autonomous continuation. Token budget
    # counts input+output only (cache excluded); budget hit flips to
    # budget_limited and steers a wrap-up ("Do not start new substantive
    # work..."). Max objective 4000 chars.
    #
    # Fill-in: owns goal state (persisted under the session dir) and the
    # turn-end continuation; the kernel-side Goal skill
    # (work/.brute/skills/goal) drives it via goal.get/create/complete
    # request files drained here.
    class Goal
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

describe "prime_agent/middleware/goal" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::Goal.new(app).call(env)
    env[:inner].should.be.true
  end
end
