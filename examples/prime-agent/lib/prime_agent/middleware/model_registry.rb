# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # ModelRegistry — per-turn middleware. SCAFFOLD: pass-through no-op
    # (FEATURES.md M14, kernel API K2).
    #
    # Ports prime-agent's model search (core/rlm-runtime.ts
    # findRlmModelMatches): a bounded fuzzy search over the authenticated
    # model catalog for KernelAgent.spawn's model: override — scoring exact <
    # prefix < substring across "provider/id", id and name; limit default 8,
    # clamped to 20; the override selector is exact "provider/model". The
    # catalog itself is never exposed in the prompt.
    #
    # Fill-in: owns the catalog fetch (OpenRouter /models) + scoring; backs
    # the KernelAgent.find_models kernel stub in kernel_agents.rb.
    class ModelRegistry
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

describe "prime_agent/middleware/model_registry" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::ModelRegistry.new(app).call(env)
    env[:inner].should.be.true
  end
end
