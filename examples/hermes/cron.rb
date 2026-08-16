# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "cron_store"
module Hermes
  # The cron tick — driver-side in the timer model. Port of hermes-agent
  # cron/scheduler.py's tick: flock (skip if another process ticks), estop
  # check, due jobs, at-most-once advance, executions ledger.
  #
  # The job runner is injected (main.rb builds the job's mini-agent).
  module Cron
    # Inactivity watchdog for cron runs: no new events for `timeout` seconds
    # → Interrupt (hermes' HERMES_CRON_TIMEOUT=600 hard interrupt).
    WATCHDOG_TIMEOUT = 600

    module_function

    def tick(store:, run_job:, now: Time.now,
             estop_path: File.join(Dir.pwd, ".estop"),
             lock_path: File.join(Dir.pwd, "cron", ".tick.lock"))
      return { skipped: "estop" } if File.exist?(estop_path)

      FileUtils.mkdir_p(File.dirname(lock_path))
      lock = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
      return { skipped: "locked" } unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      begin
        fired = store.due_jobs(now: now).map do |job|
          result = run_job.call(job)
          ok = result[:ok] ? true : false
          store.record_fired(job, status: ok ? "ok" : "error", error: result[:error], now: now)
          store.record_execution(job_id: job["id"], state: ok ? "completed" : "failed",
                                 error: result[:error], output_path: result[:output_path])
          { "id" => job["id"], "name" => job["name"], "status" => ok ? "ok" : "error" }
        end
        { "fired" => fired }
      ensure
        lock.flock(File::LOCK_UN)
        lock.close
      end
    end

    # Run a block with the inactivity watchdog: no new events for
    # WATCHDOG_TIMEOUT seconds → Hermes::Interrupt.request! (the loop unwinds
    # gracefully). Stops when the block returns.
    def with_watchdog(events:, timeout: WATCHDOG_TIMEOUT)
      done = false
      last_count = events.respond_to?(:size) ? events.size : 0
      last_change = Time.now

      watcher = Thread.new do
        until done
          sleep 5
          count = events.respond_to?(:size) ? events.size : 0
          if count != last_count
            last_count = count
            last_change = Time.now
          elsif Time.now - last_change > timeout
            Hermes::Interrupt.request!
            break
          end
        end
      end

      yield
    ensure
      done = true
      watcher&.join(1)
    end
  end
end
