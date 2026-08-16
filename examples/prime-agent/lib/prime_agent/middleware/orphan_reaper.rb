# frozen_string_literal: true

require "fileutils"
require "json"

module PrimeAgent
  module Middleware
    # OrphanReaper — run-lifecycle middleware (outermost, pairs with
    # KernelLifecycle). The port of prime-agent's orphan-process-journal.ts
    # reapers: at run end, read the kernel's spawn journal
    # (orphans.jsonl, written by the kernel's Process.spawn wrapper), and
    # SIGKILL the process GROUP of every journaled pid that is still alive
    # AND identity-current — the /proc start-time token means a recycled pid
    # is never killed. The journal is cleared afterwards.
    class OrphanReaper
      def initialize(app, journal_path:)
        @app = app
        @journal_path = journal_path
      end

      def call(env)
        @app.call(env)
      ensure
        reap
      end

      private

      def reap
        return unless @journal_path && File.exist?(@journal_path)

        active_pids.each do |pid, start_id|
          next unless identity_current?(pid, start_id)

          begin
            Process.kill("KILL", -pid) # the process group
          rescue Errno::ESRCH, Errno::EPERM
            begin
              Process.kill("KILL", pid) # fallback: the bare pid
            rescue Errno::ESRCH, Errno::EPERM
              nil
            end
          end
        end
        File.delete(@journal_path)
      rescue StandardError
        nil # reaping is best-effort
      end

      def active_pids
        File.foreach(@journal_path).filter_map do |line|
          record =
            begin
              JSON.parse(line)
            rescue JSON::ParserError
              nil
            end
          next unless record.is_a?(Hash) && record["pid"].is_a?(Integer)

          [record["pid"], record["start_id"]]
        end
      end

      def identity_current?(pid, start_id)
        return false if start_id.nil?

        current = File.read("/proc/#{pid}/stat").split[21]
        current == start_id.to_s
      rescue StandardError
        false # the process is gone (or unreadable) — nothing to reap
      end
    end
  end
end

__END__

describe "prime_agent/middleware/orphan_reaper" do
  require "json"
  require "tmpdir"

  it "kills journaled live process groups and clears the journal" do
    Dir.mktmpdir do |dir|
      journal = File.join(dir, "orphans.jsonl")
      child = Process.spawn("sleep", "60")
      start_id = File.read("/proc/#{child}/stat").split[21]
      File.write(journal, "#{JSON.generate("pid" => child, "start_id" => start_id)}\n")

      app = ->(env) { env }
      PrimeAgent::Middleware::OrphanReaper.new(app, journal_path: journal).call({})

      File.exist?(journal).should.be.false
      begin
        Process.waitpid(child)
      rescue Errno::ECHILD
        nil
      end
      begin
        Process.kill(0, child)
        alive = true
      rescue Errno::ESRCH
        alive = false
      end
      alive.should.be.false
    end
  end

  it "never kills a recycled pid" do
    Dir.mktmpdir do |dir|
      journal = File.join(dir, "orphans.jsonl")
      # a journal entry whose start_id does not match the live process
      live = Process.spawn("sleep", "60")
      File.write(journal, "#{JSON.generate("pid" => live, "start_id" => "999999999")}\n")

      PrimeAgent::Middleware::OrphanReaper.new(->(env) { env }, journal_path: journal).call({})

      begin
        Process.kill(0, live)
        alive = true
      rescue Errno::ESRCH
        alive = false
      end
      alive.should.be.true # mismatched identity: left alone
      Process.kill("KILL", live)
      Process.waitpid(live)
    end
  end

  it "is a no-op without a journal" do
    Dir.mktmpdir do |dir|
      app = ->(env) { env[:ran] = true; env }
      PrimeAgent::Middleware::OrphanReaper.new(app, journal_path: File.join(dir, "nope"))
        .call({})
        .should == { ran: true }
    end
  end
end
