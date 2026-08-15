# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # KernelSnapshot — run-lifecycle middleware (pairs with
    # KernelLifecycle). SCAFFOLD: pass-through no-op (FEATURES.md M17).
    #
    # Ports prime-agent's kernel state snapshots (core/kernel/index.ts
    # snapshotState/restoreState + core/kernel/state-snapshot.ts): the
    # kernel's namespace is checkpointed (upstream: dill; here: Marshal where
    # possible) so a resumed session revives variables, imports and task
    # state on a best-effort basis — unserializable objects are dropped and
    # reported. Snapshot debounced 1500ms after every ok execute, capped at
    # 256 MiB, with a bounded final snapshot on shutdown; restore runs before
    # the bootstrap cell so live handles shadow restored names.
    #
    # Fill-in: hooks KernelProvisioner/KernelManager; needed only when
    # sessions persist across runs — defer with SessionTree.
    class KernelSnapshot
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

describe "prime_agent/middleware/kernel_snapshot" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::KernelSnapshot.new(app).call(env)
    env[:inner].should.be.true
  end
end
