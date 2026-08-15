# frozen_string_literal: true

# Hermes::Middleware::CronSchedule — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `cron/jobs.py + tools/cronjob_tools.py`:
# # installs the `cronjob` tool (create|list|update|pause|resume|remove|run) over the jobs store;
# schedule formats (duration/every/cron-expr/ISO); agent cannot pin model/provider; jobs created
# inside cron runs default disabled. The ticker itself is driver-side.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class CronSchedule
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
