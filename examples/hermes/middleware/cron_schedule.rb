# frozen_string_literal: true

require_relative "../cron_store"
require_relative "../tools/cronjob"

module Hermes
  module Middleware
    # CronSchedule — installs the cronjob tool (per-turn). Port of hermes-agent
    # tools/cronjob_tools.py's wiring. The tick loop itself is driver-side
    # (Hermes::Cron.tick, called from main.rb on each invocation).
    #
    # Before: build the CronStore over <dir>/jobs.json and install the tool
    # via env[:provided_tools]. `in_cron:` marks this agent as a cron-run
    # context (jobs it creates default to disabled). `runner:` is the job
    # runner proc for action=run (nil in contexts where running isn't allowed).
    class CronSchedule
      def initialize(app, dir: File.join(Dir.pwd, "cron"), runner: nil, in_cron: false)
        @app = app
        @dir = dir
        @runner = runner
        @in_cron = in_cron
      end

      def call(env)
        store = Hermes::CronStore.new(@dir)
        env[:cron_store] = store
        env[:provided_tools] = Array(env[:provided_tools]) << HermesTools::Cronjob.new(
          store: store, runner: @runner, in_cron: @in_cron,
        )
        @app.call(env)
      end
    end
  end
end
