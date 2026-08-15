# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module PrimeAgent
  # CronStore — the scheduled-prompt job store. The port of prime-agent's
  # core/cron-jobs.ts (AgentCronJobStore), adapted to this port's delivery
  # model: there is no resident session to steer into, so a due job is
  # delivered by RUNNING the agent with the job's prompt (see
  # ScheduleDriver). Heartbeats are ordinary jobs with a `source` tag.
  #
  # One JSON file holds both the jobs and a dispatch ledger:
  #
  #   { "jobs": [...], "dispatches": [ { id, jobId, claimedAt, scheduledFor } ] }
  #
  # The ledger is where crash-correctness lives (claimDueInState,
  # cron-jobs.ts:1574):
  #  - claim_due appends a dispatch record AND advances next_run_at BEFORE
  #    anything runs — no matter how many intervals elapsed while nothing
  #    claimed them, exactly one dispatch exists and the schedule resumes
  #    from claim time (missed ticks coalesce; never a replayed backlog).
  #  - a job with an outstanding dispatch (previous run still in flight) is
  #    skipped and only last_skipped_at is stamped — no overlap, ever.
  #  - recover_interrupted clears the ledger after a crash, stamping
  #    "Interrupted before scheduled operation completion" (once jobs become
  #    completed) — at-most-once with an explicit uncertainty record.
  #
  # Writes are atomic (tmp + rename) and serialized with flock, so the
  # kernel's rlm_heartbeat proxy can write the same store directly — the
  # dual-writer pattern harness_state.json already uses.
  #
  # Pure stdlib — loadable without brute or any gem.
  class CronStore
    INTERRUPTED_ERROR = "Interrupted before scheduled operation completion"
    MIN_INTERVAL_SECONDS = 10 # "Recurring interval must be at least 10 seconds"

    SOURCES = %w[cron heartbeat rlm_heartbeat].freeze
    DELIVERY_MODES = %w[steer follow_up].freeze
    # Upstream default (cron-jobs.ts:116). In the driver model the delivery
    # mode is stored as metadata only — every delivery is effectively
    # follow_up (a due job starts a run; there is no live turn to steer).
    DEFAULT_HEARTBEAT_SCHEDULE = "every 5m"
    DEFAULT_DELIVERY_MODE = "steer"

    Job = Data.define(
      :id, :status, :source, :delivery_mode, :label, :prompt, :schedule,
      :created_at, :updated_at, :next_run_at, :last_run_at, :last_skipped_at,
      :last_error, :run_count
    )

    Dispatch = Data.define(:id, :job)

    def initialize(path)
      @path = path
    end

    # ------------------------------------------------------------------
    # Creation
    # ------------------------------------------------------------------

    # A plain scheduled prompt (prime-agent schedule add).
    def create(prompt:, schedule_text:, label: nil, source: "cron", now: Time.now.utc)
      raise ArgumentError, "unknown source #{source.inspect}" unless SOURCES.include?(source)

      schedule, next_run_at = self.class.parse_schedule(schedule_text, now: now)
      append_job(
        build_job(prompt: prompt, schedule: schedule, next_run_at: next_run_at,
                  label: label, source: source, now: now),
      )
    end

    # The user heartbeat: ONE per store. Creating cancels any existing
    # active/paused heartbeat (cron-jobs.ts:318-353); must be recurring.
    def create_heartbeat(instruction:, schedule_text: DEFAULT_HEARTBEAT_SCHEDULE, label: nil, now: Time.now.utc)
      schedule, next_run_at = self.class.parse_schedule(schedule_text, now: now)
      raise ArgumentError, "Heartbeat schedule must be recurring" if schedule["kind"] == "once"

      job = build_job(prompt: instruction, schedule: schedule, next_run_at: next_run_at,
                      label: label, source: "heartbeat", now: now)
      with_state do |state|
        state["jobs"].each do |existing|
          next unless existing["source"] == "heartbeat" && %w[active paused].include?(existing["status"])

          existing["status"] = "cancelled"
          existing["next_run_at"] = nil
          existing["updated_at"] = serialize_time(now)
        end
        state["jobs"] << serialize_job(job)
      end
      job
    end

    # Agent-owned heartbeats (rlm_heartbeat.create): many per store, no cap.
    def create_rlm_heartbeat(instruction:, interval: nil, label: nil, delivery_mode: nil, now: Time.now.utc)
      schedule_text = interval || DEFAULT_HEARTBEAT_SCHEDULE
      schedule, next_run_at = self.class.parse_schedule(schedule_text, now: now)
      raise ArgumentError, "Heartbeat schedule must be recurring" if schedule["kind"] == "once"

      mode = normalize_delivery_mode(delivery_mode)
      append_job(
        build_job(prompt: instruction, schedule: schedule, next_run_at: next_run_at,
                  label: label, source: "rlm_heartbeat", delivery_mode: mode, now: now),
      )
    end

    # ------------------------------------------------------------------
    # rlm_heartbeat management (the kernel proxy's surface)
    # ------------------------------------------------------------------

    def list_rlm_heartbeats(include_inactive: false)
      read_state["jobs"]
        .select { |job| job["source"] == "rlm_heartbeat" }
        .select { |job| include_inactive || job["status"] == "active" }
        .map { |job| Job.new(**symbolize(job)) }
    end

    def update_rlm_heartbeat(id, instruction: nil, interval: nil, label: nil, status: nil, delivery_mode: nil, now: Time.now.utc)
      unless status.nil? || %w[pause resume].include?(status)
        raise ArgumentError, %(status must be "pause", "resume", or nil)
      end

      mode = normalize_delivery_mode(delivery_mode)
      with_state do |state|
        job = find_rlm_heartbeat(state, id)
        job["prompt"] = instruction.strip unless instruction.nil?
        raise ArgumentError, "Heartbeat instruction cannot be empty" if job["prompt"].empty?

        unless interval.nil?
          schedule, next_run_at = self.class.parse_schedule(interval, now: now)
          raise ArgumentError, "Heartbeat schedule must be recurring" if schedule["kind"] == "once"

          job["schedule"] = schedule
          job["next_run_at"] = serialize_time(next_run_at)
        end
        job["label"] = label unless label.nil?
        job["delivery_mode"] = mode unless mode.nil?
        case status
        when "pause" then job["status"] = "paused"
        when "resume"
          job["status"] = "active"
          job["next_run_at"] ||= serialize_time(self.class.next_run_at_for(job["schedule"], now))
        end
        job["updated_at"] = serialize_time(now)
        Job.new(**symbolize(job))
      end
    end

    def delete_rlm_heartbeat(id)
      with_state do |state|
        job = find_rlm_heartbeat(state, id)
        state["jobs"].delete_if { |candidate| candidate["id"] == job["id"] }
        Job.new(**symbolize(job))
      end
    end

    def heartbeat
      read_state["jobs"]
        .select { |job| job["source"] == "heartbeat" && %w[active paused].include?(job["status"]) }
        .map { |job| Job.new(**symbolize(job)) }
        .first
    end

    # ------------------------------------------------------------------
    # Claiming + results (the driver surface)
    # ------------------------------------------------------------------

    # Claim every due job. Returns Dispatch records; each claimed job's
    # next_run_at has ALREADY advanced (missed-tick coalescing), and a job
    # whose previous dispatch is still outstanding is skipped (last_skipped_at).
    def claim_due(now: Time.now.utc)
      with_state do |state|
        claimed_ids = state["dispatches"].map { |dispatch| dispatch["jobId"] }
        dispatches = []
        state["jobs"].each do |job|
          next unless due?(job, now)

          scheduled_for = job["next_run_at"]
          job["next_run_at"] = serialize_time(self.class.next_run_at_for(job["schedule"], now))
          job["updated_at"] = serialize_time(now)
          if claimed_ids.include?(job["id"])
            job["last_skipped_at"] = serialize_time(now)
            next
          end

          record = {
            "id" => SecureRandom.uuid,
            "jobId" => job["id"],
            "claimedAt" => serialize_time(now),
            "scheduledFor" => scheduled_for,
          }
          state["dispatches"] << record
          dispatches << Dispatch.new(id: record["id"], job: Job.new(**symbolize(job)))
        end
        dispatches
      end
    end

    # Record the outcome of a claimed dispatch (recordDispatchResult,
    # cron-jobs.ts:715-755): a skip without error recomputes next_run_at and
    # stamps last_skipped_at; anything else stamps last_run_at, increments
    # run_count, records last_error, and completes once jobs.
    def record_result(dispatch_id, outcome:, error: nil, now: Time.now.utc)
      with_state do |state|
        dispatch = state["dispatches"].find { |record| record["id"] == dispatch_id }
        return unless dispatch

        state["dispatches"].delete(dispatch)
        job = state["jobs"].find { |candidate| candidate["id"] == dispatch["jobId"] }
        return unless job

        if outcome == "skipped" && error.nil?
          job["next_run_at"] = serialize_time(self.class.next_run_at_for(job["schedule"], now))
          job["last_skipped_at"] = serialize_time(now)
        else
          job["last_run_at"] = serialize_time(now)
          job["run_count"] += 1
          job["last_error"] = error ? "#{error.class}: #{error.message}" : nil
          job["status"] = "completed" if job["schedule"]["kind"] == "once"
        end
        job["updated_at"] = serialize_time(now)
      end
      nil
    end

    # Crash recovery: any outstanding dispatch means "claimed but unknown
    # whether it ran" — clear the ledger and stamp the jobs.
    def recover_interrupted(now: Time.now.utc)
      with_state do |state|
        interrupted_ids = state["dispatches"].map { |dispatch| dispatch["jobId"] }
        next [] if interrupted_ids.empty?

        state["dispatches"] = []
        recovered = []
        state["jobs"].each do |job|
          next unless interrupted_ids.include?(job["id"]) && job["status"] == "active"

          job["status"] = "completed" if job["schedule"]["kind"] == "once"
          job["last_error"] = INTERRUPTED_ERROR
          job["updated_at"] = serialize_time(now)
          recovered << Job.new(**symbolize(job))
        end
        recovered
      end
    end

    # The next active run across all jobs (driver sleep target), or nil.
    def next_active_run_at
      read_state["jobs"]
        .select { |job| job["status"] == "active" && job["next_run_at"] }
        .map { |job| Time.parse(job["next_run_at"]) }
        .min
    end

    def jobs
      read_state["jobs"].map { |job| Job.new(**symbolize(job)) }
    end

    # ------------------------------------------------------------------
    # Schedule parsing (parseAgentCronSchedule, cron-jobs.ts:1079-1139)
    # ------------------------------------------------------------------

    CRON_ALIASES = {
      "@hourly" => "0 * * * *",
      "@daily" => "0 0 * * *",
      "@weekly" => "0 0 * * 0",
      "@monthly" => "0 0 * * 1",
    }.freeze

    # Parse schedule text into [schedule, next_run_at(Time)].
    # Syntaxes: "in 30m", "every 5m" (min 10s recurring), "at <ISO8601>",
    # 5-field cron (minute hour day month weekday) with the @-aliases.
    def self.parse_schedule(text, now: Time.now.utc)
      stripped = text.strip
      case stripped
      when /\Ain\s+(\d+)\s*([mhd])\z/
        seconds = Regexp.last_match(1).to_i * { "m" => 60, "h" => 3600, "d" => 86_400 }[Regexp.last_match(2)]
        [{ "kind" => "once", "expression" => stripped }, now + seconds]
      when /\A(?:(?:every|each)\s+)?(\d+)\s*([smh])\z/
        # "every 5m" and bare "5m" (heartbeat interval shorthand) both parse
        # as recurring intervals, subject to the 10-second floor.
        seconds = Regexp.last_match(1).to_i * { "s" => 1, "m" => 60, "h" => 3600 }[Regexp.last_match(2)]
        if seconds < MIN_INTERVAL_SECONDS
          raise ArgumentError, "Recurring interval must be at least #{MIN_INTERVAL_SECONDS} seconds"
        end

        [{ "kind" => "interval", "expression" => stripped, "interval_seconds" => seconds }, now + seconds]
      when /\Aat\s+(.+)\z/
        at = Time.iso8601(Regexp.last_match(1).strip)
        raise ArgumentError, "One-time schedule must be in the future" unless at > now

        [{ "kind" => "once", "expression" => stripped }, at]
      else
        expression = CRON_ALIASES.fetch(stripped, stripped)
        fields = parse_cron_expression(expression)
        [{ "kind" => "cron", "expression" => expression }, next_cron_run_after(fields, now)]
      end
    end

    # The next run after `after` for a parsed schedule, or nil for one-shots.
    def self.next_run_at_for(schedule, after)
      case schedule["kind"]
      when "once" then nil
      when "interval" then after + schedule["interval_seconds"]
      when "cron" then next_cron_run_after(parse_cron_expression(schedule["expression"]), after)
      end
    end

    def self.parse_cron_expression(expression)
      parts = expression.strip.split(/\s+/)
      unless parts.length == 5
        raise ArgumentError,
              "Unsupported cron schedule. Use 'in 10m', 'at <ISO date>', @hourly, " \
              "or five fields: minute hour day month weekday"
      end

      {
        minute: parse_cron_field(parts[0], 0, 59),
        hour: parse_cron_field(parts[1], 0, 23),
        day_of_month: parse_cron_field(parts[2], 1, 31),
        month: parse_cron_field(parts[3], 1, 12),
        day_of_week: parse_cron_field(parts[4], 0, 7),
      }
    end

    # One cron field to a sorted array of values: *, lists, ranges, steps.
    def self.parse_cron_field(field, min, max)
      values = []
      field.split(",").each do |part|
        raise ArgumentError, "Invalid cron field: #{field}" if part.empty?

        range_text, step_text = part.split("/")
        step = step_text.nil? ? 1 : parse_cron_number(step_text, 1, max)
        start, finish =
          if range_text == "*"
            [min, max]
          elsif range_text.include?("-")
            bounds = range_text.split("-").map { |bound| parse_cron_number(bound, min, max) }
            raise ArgumentError, "Invalid cron range: #{range_text}" if bounds[0] > bounds[1]

            bounds
          else
            value = parse_cron_number(range_text, min, max)
            [value, value]
          end
        start.step(finish, step) { |value| values << value }
      end
      values.uniq.sort
    end

    def self.parse_cron_number(value, min, max)
      raise ArgumentError, "Invalid cron number: #{value}" unless value&.match?(/\A\d+\z/)

      parsed = Integer(value, 10)
      raise ArgumentError, "Cron number out of range: #{value}" if parsed < min || parsed > max

      parsed
    end

    # Minute-by-minute scan, up to 366 days out (nextCronRunAfter).
    def self.next_cron_run_after(fields, after)
      candidate = (after + 60).utc
      candidate -= candidate.sec # truncate to the minute
      deadline = after + 366 * 86_400
      while candidate <= deadline
        return candidate if cron_match?(candidate, fields)

        candidate += 60
      end
      raise ArgumentError, "Cron schedule did not match within one year"
    end

    # All five fields AND (upstream matchesCronFields); Sunday is 0 or 7.
    def self.cron_match?(time, fields)
      fields[:minute].include?(time.min) &&
        fields[:hour].include?(time.hour) &&
        fields[:day_of_month].include?(time.day) &&
        fields[:month].include?(time.month) &&
        (fields[:day_of_week].include?(time.wday) || (time.wday.zero? && fields[:day_of_week].include?(7)))
    end

    private

    def build_job(prompt:, schedule:, next_run_at:, label:, source:, now:, delivery_mode: nil)
      stripped = prompt.to_s.strip
      raise ArgumentError, "Heartbeat instruction cannot be empty" if stripped.empty?

      now_iso = serialize_time(now)
      Job.new(
        id: SecureRandom.uuid,
        status: "active",
        source: source,
        delivery_mode: delivery_mode || DEFAULT_DELIVERY_MODE,
        label: label,
        prompt: stripped,
        schedule: schedule,
        created_at: now_iso,
        updated_at: now_iso,
        next_run_at: serialize_time(next_run_at),
        last_run_at: nil,
        last_skipped_at: nil,
        last_error: nil,
        run_count: 0,
      )
    end

    def append_job(job)
      with_state { |state| state["jobs"] << serialize_job(job) }
      job
    end

    def serialize_job(job)
      job.to_h.transform_keys(&:to_s)
    end

    def find_rlm_heartbeat(state, id)
      job = state["jobs"].find { |candidate| candidate["source"] == "rlm_heartbeat" && candidate["id"] == id }
      raise "no rlm_heartbeat job #{id.inspect}" unless job

      job
    end

    def normalize_delivery_mode(mode)
      return nil if mode.nil?
      unless DELIVERY_MODES.include?(mode)
        raise ArgumentError, %(delivery_mode must be "steer", "follow_up", or nil)
      end

      mode
    end

    def due?(job, now)
      job["status"] == "active" && job["next_run_at"] && Time.parse(job["next_run_at"]) <= now
    end

    def serialize_time(time)
      time&.utc&.iso8601
    end

    def symbolize(job)
      job.to_h { |key, value| [key.to_sym, value] }
    end

    def read_state
      return { "jobs" => [], "dispatches" => [] } unless File.exist?(@path)

      data = JSON.parse(File.read(@path))
      data = {} unless data.is_a?(Hash)
      { "jobs" => Array(data["jobs"]), "dispatches" => Array(data["dispatches"]) }
    rescue JSON::ParserError
      { "jobs" => [], "dispatches" => [] }
    end

    # Read-modify-write under an exclusive flock; the write is atomic
    # (tmp + rename). The block's return value is the method's result.
    def with_state
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        state =
          begin
            data = JSON.parse(file.read)
            data.is_a?(Hash) ? data : {}
          rescue JSON::ParserError
            {}
          end
        state = { "jobs" => Array(state["jobs"]), "dispatches" => Array(state["dispatches"]) }

        result = yield state

        tmp = "#{@path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(state)}\n")
        File.rename(tmp, @path)
        result
      end
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/cron_store" do
  T0 = Time.utc(2026, 8, 15, 12, 0, 0)

  def store(dir)
    PrimeAgent::CronStore.new(File.join(dir, "scheduled-jobs.json"))
  end

  describe "schedule parsing" do
    S = PrimeAgent::CronStore

    it 'parses "in 30m" as a one-shot 30 minutes out' do
      schedule, next_run = S.parse_schedule("in 30m", now: T0)
      schedule["kind"].should == "once"
      next_run.should == T0 + 1800
    end

    it 'parses "every 5m" as an interval and enforces the 10s floor' do
      schedule, next_run = S.parse_schedule("every 5m", now: T0)
      schedule.should == { "kind" => "interval", "expression" => "every 5m", "interval_seconds" => 300 }
      next_run.should == T0 + 300
      lambda { S.parse_schedule("every 5s", now: T0) }.should.raise(ArgumentError)
    end

    it 'parses "at <ISO>" only in the future' do
      schedule, at = S.parse_schedule("at 2026-08-15T13:00:00Z", now: T0)
      at.should == Time.utc(2026, 8, 15, 13, 0, 0)
      lambda { S.parse_schedule("at 2026-08-15T11:00:00Z", now: T0) }.should.raise(ArgumentError)
    end

    it "parses 5-field cron and aliases, AND-matching all fields" do
      _, next_run = S.parse_schedule("0 9 * * 1-5", now: T0) # T0 is a Saturday
      next_run.should == Time.utc(2026, 8, 17, 9, 0, 0)      # Monday 09:00

      _, hourly = S.parse_schedule("@hourly", now: T0)
      hourly.should == Time.utc(2026, 8, 15, 13, 0, 0)

      _, ninth = S.parse_schedule("*/15 * * * *", now: T0)
      ninth.should == Time.utc(2026, 8, 15, 12, 15, 0)
    end

    it "rejects garbage" do
      lambda { S.parse_schedule("whenever", now: T0) }.should.raise(ArgumentError)
      lambda { S.parse_schedule("61 * * * *", now: T0) }.should.raise(ArgumentError)
    end

    it "next_run_at_for advances intervals from the claim time and ends one-shots" do
      S.next_run_at_for({ "kind" => "once" }, T0).should.be.nil
      S.next_run_at_for({ "kind" => "interval", "interval_seconds" => 60 }, T0).should == T0 + 60
    end
  end

  describe "claim_due / record_result / recover" do
    it "claims a due job once, advancing next_run_at at claim time" do
      Dir.mktmpdir do |dir|
        s = store(dir)
        s.create(prompt: "tick", schedule_text: "every 10m", now: T0)

        dispatches = s.claim_due(now: T0 + 3600) # an hour late: 6 missed ticks
        dispatches.length.should == 1            # coalesced — never a backlog
        dispatches.first.job.prompt.should == "tick"
        dispatches.first.job.next_run_at.should == (T0 + 3600 + 600).iso8601

        s.claim_due(now: T0 + 3600).should == [] # already claimed
      end
    end

    it "skips a job whose previous dispatch is still outstanding" do
      Dir.mktmpdir do |dir|
        s = store(dir)
        s.create(prompt: "tick", schedule_text: "every 10m", now: T0)
        s.claim_due(now: T0 + 600)
        s.claim_due(now: T0 + 1200).should == []
        s.jobs.first.last_skipped_at.should.not.be.nil
      end
    end

    it "records results: run_count, last_run_at, completion of one-shots, errors" do
      Dir.mktmpdir do |dir|
        s = store(dir)
        once = s.create(prompt: "one shot", schedule_text: "in 30m", now: T0)
        dispatch = s.claim_due(now: T0 + 1800).first
        s.record_result(dispatch.id, outcome: "ran", now: T0 + 1801)
        job = s.jobs.first
        job.status.should == "completed"
        job.run_count.should == 1
        job.last_run_at.should == (T0 + 1801).iso8601

        s.create(prompt: "boom", schedule_text: "every 10m", now: T0)
        dispatch = s.claim_due(now: T0 + 2400).first
        s.record_result(dispatch.id, outcome: "ran", error: RuntimeError.new("kablam"), now: T0 + 2401)
        s.jobs.find { |j| j.prompt == "boom" }.last_error.should == "RuntimeError: kablam"
      end
    end

    it "recovers interrupted dispatches with the uncertainty record" do
      Dir.mktmpdir do |dir|
        s = store(dir)
        s.create(prompt: "one shot", schedule_text: "in 30m", now: T0)
        s.claim_due(now: T0 + 1800)
        recovered = s.recover_interrupted(now: T0 + 1802)
        recovered.length.should == 1
        job = s.jobs.first
        job.last_error.should == PrimeAgent::CronStore::INTERRUPTED_ERROR
        job.status.should == "completed" # once jobs don't replay after a crash
        s.claim_due(now: T0 + 7200).should == []
      end
    end
  end

  describe "heartbeats" do
    it "user heartbeat is a singleton: creating cancels the previous one" do
      Dir.mktmpdir do |dir|
        s = store(dir)
        first = s.create_heartbeat(instruction: "check the deployment", now: T0)
        second = s.create_heartbeat(instruction: "check it harder", schedule_text: "every 10m", now: T0 + 60)
        s.jobs.find { |j| j.id == first.id }.status.should == "cancelled"
        s.heartbeat.id.should == second.id
        s.heartbeat.schedule["interval_seconds"].should == 600
      end
    end

    it "rejects one-shot heartbeats and empty instructions" do
      Dir.mktmpdir do |dir|
        s = store(dir)
        lambda { s.create_heartbeat(instruction: "x", schedule_text: "in 30m") }.should.raise(ArgumentError)
        lambda { s.create_heartbeat(instruction: "  ") }.should.raise(ArgumentError)
      end
    end

    it "rlm heartbeats are multi with full CRUD and pause/resume" do
      Dir.mktmpdir do |dir|
        s = store(dir)
        a = s.create_rlm_heartbeat(instruction: "check tests", now: T0)
        b = s.create_rlm_heartbeat(instruction: "check deploy", interval: "every 1h", label: "deploy", now: T0)
        a.schedule["interval_seconds"].should == 300 # default "every 5m"
        a.delivery_mode.should == "steer"
        s.list_rlm_heartbeats.length.should == 2

        updated = s.update_rlm_heartbeat(a.id, status: "pause", now: T0 + 60)
        updated.status.should == "paused"
        s.list_rlm_heartbeats.map(&:id).should == [b.id]
        s.list_rlm_heartbeats(include_inactive: true).length.should == 2

        resumed = s.update_rlm_heartbeat(a.id, status: "resume", interval: "every 30m", now: T0 + 120)
        resumed.status.should == "active"
        resumed.schedule["interval_seconds"].should == 1800
        resumed.next_run_at.should == (T0 + 120 + 1800).iso8601

        lambda { s.update_rlm_heartbeat(a.id, status: "explode") }.should.raise(ArgumentError)
        lambda { s.update_rlm_heartbeat(a.id, delivery_mode: "yell") }.should.raise(ArgumentError)

        s.delete_rlm_heartbeat(a.id)
        s.list_rlm_heartbeats(include_inactive: true).length.should == 1
        lambda { s.delete_rlm_heartbeat("nope") }.should.raise(RuntimeError)
      end
    end

    it "next_active_run_at is the earliest active tick, nil when none" do
      Dir.mktmpdir do |dir|
        s = store(dir)
        s.next_active_run_at.should.be.nil
        s.create(prompt: "later", schedule_text: "every 1h", now: T0)
        s.create(prompt: "sooner", schedule_text: "every 10m", now: T0)
        s.next_active_run_at.should == T0 + 600
      end
    end
  end
end
