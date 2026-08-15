# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"
require "time"
require "fugit"

# picoclaw-clone's cron store — ported from picoclaw's pkg/cron.
#
# The store shape mirrors picoclaw's cron/jobs.json. Their in-process run
# loop is replaced by the systemd timer: each tick, the CronSchedule
# middleware fires due jobs (command jobs run through the exec tool; message
# jobs are injected into the heartbeat turn); the agent manages jobs through
# the CronTool. Cron expressions are parsed by fugit.
#
# Schedules: { kind: "at", at: unix } | { kind: "every", every_seconds: n } |
# { kind: "cron", expr: "0 9 * * *" } (upstream: atMs/everyMs/expr).
class CronStore
  attr_reader :jobs

  def initialize(path)
    @path = path
    @jobs = []
    @dirty = false
  end

  def dirty? = @dirty

  # Mark the store as changed (for mutations the store can't see, e.g. the
  # tool toggling job[:enabled]). The middleware saves when dirty.
  def touch
    @dirty = true
  end

  def load
    @jobs = if File.exist?(@path)
              JSON.parse(File.read(@path), symbolize_names: true).fetch(:jobs, []).map { |j| migrate(j) }
            else
              []
            end
    self
  end

  def save
    FileUtils.mkdir_p(File.dirname(@path))
    tmp = "#{@path}.tmp"
    File.write(tmp, "#{JSON.pretty_generate({ version: 1, jobs: @jobs })}\n")
    File.rename(tmp, @path) # atomic-ish, like picoclaw's WriteFileAtomic
    @dirty = false
    self
  end

  def add(name:, schedule:, message:, command: nil, channel: "cli", chat_id: "direct")
    job = {
      id: SecureRandom.hex(8), # upstream: 8 crypto bytes, hex
      name: name,
      enabled: true,
      schedule: schedule,
      payload: { message: message, channel: channel, chat_id: chat_id },
      state: { next_run_at: next_run(schedule) },
      delete_after_run: schedule[:kind] == "at",
      created_at: Time.now.to_i,
    }
    job[:payload][:command] = command unless command.to_s.empty?
    @jobs << job
    @dirty = true
    job
  end

  # UpdateJob port: touches updated_at; recomputes next_run only when the
  # enabled flag or the schedule changed; disabled jobs have no next run.
  def update(job)
    found = find(job[:id])
    return false unless found

    if found[:enabled] != job[:enabled] || found[:schedule] != job[:schedule]
      job[:state][:next_run_at] = job[:enabled] ? next_run(job[:schedule]) : nil
    elsif !job[:enabled]
      job[:state][:next_run_at] = nil
    end
    job[:updated_at] = Time.now.to_i
    @jobs[@jobs.index { |j| j[:id] == job[:id] }] = job
    @dirty = true
    true
  end

  def enable(id, flag)
    job = find(id)
    return nil unless job

    updated = Marshal.load(Marshal.dump(job)) # clone: update() compares against the stored copy
    updated[:enabled] = flag
    update(updated)
    find(id)
  end

  def remove(id)
    @dirty = true if @jobs.reject! { |j| j[:id] == id }
  end

  def find(id)
    @jobs.find { |j| j[:id] == id }
  end

  def due(now = Time.now)
    @jobs.select { |j| j[:enabled] && j.dig(:state, :next_run_at).to_i > 0 && j[:state][:next_run_at] <= now.to_i }
  end

  # picoclaw's computeNextRun: "every" slides from completion time.
  def next_run(schedule, from: Time.now)
    case schedule[:kind].to_s
    when "at"
      at = schedule[:at].to_i
      at > from.to_i ? at : nil
    when "every"
      from.to_i + schedule[:every_seconds].to_i
    when "cron", "expr"
      Fugit::Cron.parse(schedule[:expr].to_s)&.next_time(from)&.to_utc_time&.to_i
    end
  end

  private

  # Pre-upgrade jobs used every_minutes and "expr" kinds.
  def migrate(job)
    schedule = job[:schedule] || {}
    if schedule[:kind].to_s == "every" && schedule[:every_seconds].nil? && schedule[:every_minutes]
      schedule[:every_seconds] = schedule.delete(:every_minutes).to_i * 60
    end
    schedule[:kind] = "cron" if schedule[:kind].to_s == "expr"
    job
  end
end
