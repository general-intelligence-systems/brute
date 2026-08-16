# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"
require "time"
require "fugit"
require "extralite"

module Hermes
  # Cron job store — port of hermes-agent cron/jobs.py for the timer model.
  #
  # Jobs at <dir>/jobs.json. Executions ledger at <dir>/executions.db
  # (extralite). Run output at <dir>/output/<job_id>/<timestamp>.md
  # (retention: 50 files/job).
  #
  # Schedule formats (hermes parse_schedule):
  #   "30m"/"2h"/"1d"          → one-shot in N (repeat=1)
  #   "every 30m"              → interval
  #   "every monday 9am"       → cron (natural, via fugit)
  #   "0 9 * * *"              → 5-field cron expression
  #   "2026-06-01T09:00:00Z"   → ISO one-shot
  #
  # Catch-up: grace = half the period clamped to [120s, 7200s]; one-shots get
  # 120s. Stale recurring jobs fast-forward next_run_at (no burst) but fire
  # once now. At-most-once: advance happens at fire time.
  class CronStore
    ONESHOT_GRACE_SECONDS = 120
    OUTPUT_RETENTION = 50

    attr_reader :dir

    def initialize(dir)
      @dir = dir
      @jobs_path = File.join(dir, "jobs.json")
      load
    end

    # -- Schedules ---------------------------------------------------------------

    def self.parse_schedule(str, now: Time.now)
      s = str.to_s.strip
      case s
      when /\A(\d+)([smhd])\z/
        { "kind" => "once", "run_at" => (now + duration_seconds($1, $2)).to_f, "repeat" => 1 }
      when /\Aevery\s+(\d+)([smhd])\z/i
        { "kind" => "interval", "seconds" => duration_seconds($1, $2) }
      when /\Aevery\s+(.+)\z/i
        cron = Fugit::Cron.parse($1) || begin
          parsed = Fugit.parse("every #{$1}")
          parsed.is_a?(Fugit::Cron) ? parsed : nil
        rescue StandardError
          nil
        end
        raise ArgumentError, "unparseable schedule: #{s}" unless cron

        { "kind" => "cron", "expr" => cron.to_cron_s }
      when /\A\d{4}-\d{2}-\d{2}[T ]/
        { "kind" => "once", "run_at" => Time.iso8601(s).to_f, "repeat" => 1 }
      else
        cron = Fugit::Cron.parse(s)
        raise ArgumentError, "unparseable schedule: #{s}" unless cron

        { "kind" => "cron", "expr" => cron.to_cron_s }
      end
    end

    def self.duration_seconds(num, unit)
      num.to_i * { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.fetch(unit)
    end

    def self.next_run_at(schedule, after: Time.now)
      case schedule["kind"]
      when "once"     then schedule["run_at"]
      when "interval" then (after.to_f + schedule["seconds"].to_i)
      when "cron"     then Fugit::Cron.parse(schedule["expr"]).next_time(after).to_f
      end
    end

    # Grace window: half the period clamped to [120s, 7200s]; one-shots 120s.
    def self.grace_seconds(job)
      sched = job["schedule"]
      case sched["kind"]
      when "once" then ONESHOT_GRACE_SECONDS
      when "interval" then (sched["seconds"] / 2.0).clamp(120.0, 7200.0)
      when "cron"
        cron = Fugit::Cron.parse(sched["expr"])
        n1 = cron.next_time(Time.now).to_f
        n2 = cron.next_time(Time.at(n1)).to_f
        ((n2 - n1) / 2.0).clamp(120.0, 7200.0)
      end
    end

    # -- CRUD --------------------------------------------------------------------

    def load
      @jobs =
        if File.exist?(@jobs_path)
          JSON.parse(File.read(@jobs_path)).fetch("jobs", [])
        else
          []
        end
      self
    rescue JSON::ParserError
      @jobs = []
      self
    end

    def save
      FileUtils.mkdir_p(@dir)
      tmp = "#{@jobs_path}.tmp"
      File.write(tmp, "#{JSON.pretty_generate({ "jobs" => @jobs })}\n")
      File.rename(tmp, @jobs_path)
      self
    end

    def all = @jobs

    def find(id) = @jobs.find { |j| j["id"] == id }

    # The agent-facing create. model/provider are NOT accepted from the agent
    # (user-owned pins — hermes' prompt-injection spend guard). Jobs created
    # inside a cron run default to disabled (cron.allow_agent_scheduling).
    def create(name:, prompt:, schedule:, skills: [], script: nil, no_agent: false,
               context_from: [], workdir: nil, deliver: "local", repeat: nil,
               created_in_cron: false, now: Time.now)
      parsed = self.class.parse_schedule(schedule, now: now)
      repeat_times = repeat&.to_i || parsed.delete("repeat")
      job = {
        "id" => SecureRandom.hex(6),
        "name" => name,
        "prompt" => prompt,
        "schedule" => parsed,
        "skills" => Array(skills),
        "script" => script,
        "no_agent" => no_agent,
        "context_from" => Array(context_from),
        "workdir" => workdir,
        "deliver" => deliver,
        "repeat" => { "times" => repeat_times, "completed" => 0 },
        "enabled" => !created_in_cron,
        "state" => created_in_cron ? "paused" : "scheduled",
        "paused_reason" => created_in_cron ? "created inside a cron run (allow_agent_scheduling=false)" : nil,
        "created_at" => now.to_f,
        "next_run_at" => self.class.next_run_at(parsed, after: now),
        "last_run_at" => nil,
        "last_status" => nil,
        "last_error" => nil,
      }
      @jobs << job
      save
      job
    end

    def update(id, **fields)
      job = find(id) or return nil
      fields.each { |k, v| job[k.to_s] = v }
      job["next_run_at"] = self.class.next_run_at(job["schedule"]) if fields[:schedule]
      save
      job
    end

    def pause(id)
      update(id, enabled: false, state: "paused", paused_at: Time.now.to_f)
    end

    def resume(id)
      job = find(id) or return nil
      job["enabled"] = true
      job["state"] = "scheduled"
      job["paused_reason"] = nil
      job["next_run_at"] = self.class.next_run_at(job["schedule"])
      save
      job
    end

    def remove(id)
      job = find(id) or return false
      @jobs.delete(job)
      save
      true
    end

    # -- Due / completion -----------------------------------------------------------

    def due_jobs(now: Time.now)
      @jobs.select do |j|
        j["enabled"] && j["next_run_at"] && j["next_run_at"] <= now.to_f &&
          (now.to_f - j["next_run_at"]) <= self.class.grace_seconds(j)
      end
    end

    # Advance after firing (at-most-once): one-shots complete; recurring
    # fast-forward to the next occurrence (no catch-up burst).
    def record_fired(job, status:, error: nil, now: Time.now)
      job["last_run_at"] = now.to_f
      job["last_status"] = status
      job["last_error"] = error
      rep = job["repeat"] ||= { "times" => nil, "completed" => 0 }
      rep["completed"] = rep["completed"].to_i + 1

      if job["schedule"]["kind"] == "once" || (rep["times"] && rep["completed"] >= rep["times"])
        job["state"] = "completed"
        job["enabled"] = false
        job["next_run_at"] = nil
      else
        job["next_run_at"] = self.class.next_run_at(job["schedule"], after: now)
      end
      save
    end

    # -- Executions ledger + output retention --------------------------------------

    def executions_db
      @executions_db ||= begin
        path = File.join(@dir, "executions.db")
        db = Extralite::Database.new(path)
        db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS executions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL,
            state TEXT NOT NULL,
            claimed_at REAL NOT NULL,
            completed_at REAL,
            error TEXT,
            output_path TEXT
          );
        SQL
        db
      end
    end

    def record_execution(job_id:, state:, error: nil, output_path: nil)
      executions_db.execute(
        "INSERT INTO executions (job_id, state, claimed_at, completed_at, error, output_path) VALUES (?, ?, ?, ?, ?, ?)",
        job_id, state, Time.now.to_f, Time.now.to_f, error, output_path,
      )
    end

    def write_output(job_id:, content:)
      dir = File.join(@dir, "output", job_id)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{Time.now.strftime('%Y%m%d-%H%M%S')}.md")
      File.write(path, content)
      prune_outputs(dir)
      path
    end

    def last_output(job_id)
      dir = File.join(@dir, "output", job_id)
      return nil unless Dir.exist?(dir)

      latest = Dir[File.join(dir, "*.md")].sort.last
      latest && File.read(latest)
    end

    private

    def prune_outputs(dir)
      files = Dir[File.join(dir, "*.md")].sort
      (files.size - OUTPUT_RETENTION).clamp(0, files.size).times { |i| File.delete(files[i]) }
    end
  end
end
