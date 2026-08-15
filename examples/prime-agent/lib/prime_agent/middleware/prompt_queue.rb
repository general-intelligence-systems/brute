# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # PromptQueue — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M10).
    #
    # Ports prime-agent's session prompt queue (core/agent-session.ts
    # _deliveryPolicy/_pumpSessionInputs): two delivery lanes —
    # "next_turn_boundary" (steer: set a stop-pending flag, let the current
    # run end at the boundary, then head the new turn with the queued
    # message) and "when_run_idle" (followUp). Busy admission WITHOUT an
    # explicit behavior raises ("Agent is already processing. Specify
    # streamingBehavior ('steer' or 'followUp')..."); duplicate follow-ups
    # with the same queueKey coalesce to one; the pump never selects while a
    # compaction/retry/bash/refine-apply is in flight.
    #
    # Fill-in: owns the lanes + coalescing; Heartbeat, AgentMessages and the
    # cron drain enqueue here instead of injecting directly. Replaces the
    # trivial Brute::Middleware::UserQueue pattern.
    class PromptQueue
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

describe "prime_agent/middleware/prompt_queue" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::PromptQueue.new(app).call(env)
    env[:inner].should.be.true
  end
end
