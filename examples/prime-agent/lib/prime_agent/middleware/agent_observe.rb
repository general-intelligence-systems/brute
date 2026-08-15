# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # AgentObserve — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M7, skill S10).
    #
    # Ports prime-agent `packages/coding-agent/src/core/agent-observe.ts`:
    # read-only observation of the agent family for orchestration. list ->
    # summaries with computed status (tool | model | compacting | busy | user
    # | idle), messageCount, and a latest-message preview truncated to 240
    # chars; get(target) -> one agent; recent(target, limit, max_chars) ->
    # last-N previews {index, role, timestamp, text, truncated, tool_calls,
    # custom_type} with limit default 8 clamped 1-50, max_chars default 800
    # clamped 80-2000; images render as "[image]". Family-reach enforced;
    # NEVER mutates the target.
    #
    # Fill-in: owns the read model over KernelAgent/session state; the
    # kernel-side AgentObserve skill drives it via agent_observe.list/get/
    # recent request files drained here.
    class AgentObserve
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

describe "prime_agent/middleware/agent_observe" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::AgentObserve.new(app).call(env)
    env[:inner].should.be.true
  end
end
