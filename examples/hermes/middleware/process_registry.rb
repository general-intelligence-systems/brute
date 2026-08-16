# frozen_string_literal: true

require_relative "../process_registry"
require_relative "../tools/process"

module Hermes
  module Middleware
    # ProcessRegistry — background processes + notify_on_complete (per-turn).
    # Installs the `process` tool and shares ONE registry into the terminal
    # tool (they must see the same processes). Completion notifications are
    # drained by the tick driver (Hermes::ProcessRegistry.check_completions).
    class ProcessRegistry
      def initialize(app, registry: nil, log_dir: File.join(Dir.pwd, "processes"))
        @app = app
        @registry = registry || Hermes::ProcessRegistry.new(log_dir: log_dir)
      end

      def call(env)
        env[:process_registry] = @registry
        env[:provided_tools] = Array(env[:provided_tools]) << HermesTools::Process.new(registry: @registry)
        @app.call(env)
      end
    end
  end
end
