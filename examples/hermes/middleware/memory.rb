# frozen_string_literal: true

require_relative "../memory_store"
require_relative "../write_approval"
require_relative "../tools/memory"

module Hermes
  module Middleware
    # Memory — per-turn middleware. Ports hermes-agent tools/memory_tool.py +
    # the agent-side wiring (agent_init / agent_runtime_helpers interception).
    #
    # Before the turn:
    #   - builds a fresh Hermes::MemoryStore over <dir>/{MEMORY,USER}.md and
    #     loads it (the frozen system-prompt snapshot is captured here)
    #   - resets the per-turn consolidation-failure budget
    #   - sets the write origin (the background-review fork passes
    #     origin: "background_review", which flips the write gate to stage-only)
    #   - installs the `memory` tool closing over the store, via
    #     env[:provided_tools] (Hermes::Middleware::ToolPipeline merges it,
    #     shadowing the statically-advertised scaffold)
    #   - exposes the frozen snapshot blocks as env[:metadata][:memory_blocks]
    #     for the system prompt's volatile tier
    class Memory
      def initialize(app, dir: File.join(Dir.pwd, "memory"), origin: "foreground")
        @app = app
        @dir = dir
        @origin = origin
      end

      def call(env)
        Hermes::WriteApproval.current_origin = @origin

        store = Hermes::MemoryStore.new(dir: @dir)
        store.load_from_disk
        store.reset_consolidation_failures!

        env[:memory_store] = store
        env[:provided_tools] = Array(env[:provided_tools]) << HermesTools::Memory.new(store)
        env[:metadata] ||= {}
        env[:metadata][:memory_blocks] = {
          memory: store.format_for_system_prompt("memory"),
          user:   store.format_for_system_prompt("user"),
        }

        @app.call(env)
      end
    end
  end
end
