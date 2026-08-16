# frozen_string_literal: true

require_relative "../delegation"
require_relative "../tools/delegate_task"

module Hermes
  module Middleware
    # Delegation — installs delegate_task (per-turn). Port of hermes-agent
    # tools/delegate_tool.py's wiring.
    #
    #   delegation: the Hermes::Delegation ledger/runner
    #   run_sync:   proc that runs a sub-agent inline (the sub-agent factory
    #               built in main.rb — leaf toolset, ephemeral prompt)
    #   main_rb:    path to main.rb for background child spawns
    #   depth:      0 for top-level agents (background allowed), 1+ for
    #               subagents (sync-only, orchestrator degrades to leaf)
    class Delegation
      def initialize(app, delegation: nil, run_sync: nil, main_rb: nil, depth: 0)
        @app = app
        @delegation = delegation || Hermes::Delegation.new
        @run_sync = run_sync
        @main_rb = main_rb
        @depth = depth
      end

      def call(env)
        env[:delegation] = @delegation
        env[:delegation_depth] = @depth
        env[:provided_tools] = Array(env[:provided_tools]) << HermesTools::DelegateTask.new(
          delegation: @delegation, run_sync: @run_sync, main_rb: @main_rb, depth: @depth,
        )
        @app.call(env)
      end
    end
  end
end
