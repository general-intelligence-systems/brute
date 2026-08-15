# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # SideQuestion — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M8).
    #
    # Ports prime-agent `packages/coding-agent/src/core/side-question.ts`
    # (the `/btw` command): ask a one-off question against the current
    # conversation WITHOUT touching the main session. A throwaway cloned
    # agent runs over a copy of env[:messages] plus replayed prior side
    # turns: no tools, exactly one turn, question wrapped
    # <side_question>...</side_question>; only the first turn prepends the
    # instruction ("Answer this side question using only the conversation
    # context above. Do not use tools..."); each follow-up re-clones the LIVE
    # main context. Nothing is persisted.
    #
    # Fill-in: builds the one-shot Brute.agent clone on demand; driver-level
    # command, not model-facing.
    class SideQuestion
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

describe "prime_agent/middleware/side_question" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::SideQuestion.new(app).call(env)
    env[:inner].should.be.true
  end
end
