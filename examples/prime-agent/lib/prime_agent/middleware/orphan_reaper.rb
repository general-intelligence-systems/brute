# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # OrphanReaper — run-lifecycle middleware (pairs with KernelLifecycle).
    # SCAFFOLD: pass-through no-op (FEATURES.md M20).
    #
    # Ports prime-agent `packages/coding-agent/src/core/orphan-process-journal.ts`:
    # an append-only JSONL journal of detached child processes (background
    # shells spawned by the agent), each record carrying a start-time
    # identity token (/proc/<pid>/stat start time) so a recycled PID is never
    # killed; on shutdown (or crash recovery) the reaper SIGKILLs the process
    # GROUP of every identity-current orphan, then clears the journal.
    #
    # Fill-in: journal detached pids from kernel-spawned background processes
    # and reap at run end. Port relevance is modest — the systemd sandbox
    # (README: Scheduled operation) already contains the run — but background
    # %%bash-style detachment is the leak vector when running unsandboxed.
    class OrphanReaper
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

describe "prime_agent/middleware/orphan_reaper" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::OrphanReaper.new(app).call(env)
    env[:inner].should.be.true
  end
end
