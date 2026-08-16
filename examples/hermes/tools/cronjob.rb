# frozen_string_literal: true

require "json"
require_relative "../cron_store"
require_relative "../threat_patterns"

module HermesTools
  # cronjob — manage scheduled jobs. Port of hermes-agent
  # tools/cronjob_tools.py (create|list|update|pause|resume|remove|run).
  #
  # Guards (hermes invariants):
  #   * model/provider/base_url are NOT tool args — per-job inference pins are
  #     user-owned, so prompt injection can't redirect spend.
  #   * create scans prompt+script for injection patterns (strict scope).
  #   * jobs created from WITHIN a cron run default to disabled.
  #   * context_from ids must exist.
  # The store and a job runner are injected per turn by CronSchedule.
  class Cronjob < Brute::Tool
    description "Manage scheduled cron jobs: create, list, update, pause, resume, remove, run."
    params({
      "type" => "object",
      "properties" => {
        "action" => { "type" => "string", "enum" => %w[create list update pause resume remove run] },
        "job_id" => { "type" => "string" },
        "name" => { "type" => "string", "description" => "Human-readable job name (create)." },
        "prompt" => { "type" => "string", "description" => "The instruction to run on schedule (create)." },
        "schedule" => { "type" => "string", "description" => "'30m' | 'every 2h' | 'every monday 9am' | '0 9 * * *' | ISO timestamp." },
        "skills" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Skills to load for the job run." },
        "script" => { "type" => "string", "description" => "Pre-run script path (stdout is injected into the prompt)." },
        "no_agent" => { "type" => "boolean", "description" => "Script-only mode: stdout IS the job output.", "default" => false },
        "context_from" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Upstream job ids whose last output is injected." },
        "workdir" => { "type" => "string", "description" => "Working directory for the run (absolute)." },
        "deliver" => { "type" => "string", "description" => "Delivery target: local|origin|all|session (default local).", "default" => "local" },
        "repeat" => { "type" => "integer", "description" => "Fire at most N times." },
        "fields" => { "type" => "object", "description" => "For update: the fields to change (name, prompt, schedule, deliver, workdir, skills)." },
      },
      "required" => ["action"],
    })

    def initialize(store: nil, runner: nil, in_cron: false)
      @store = store
      @runner = runner
      @in_cron = in_cron
    end

    def name = "cronjob"

    def execute(action:, job_id: nil, name: nil, prompt: nil, schedule: nil, skills: nil,
                script: nil, no_agent: false, context_from: nil, workdir: nil,
                deliver: "local", repeat: nil, fields: nil, **_rest)
      return err("Cron store unavailable.") unless @store

      case action
      when "create"   then create_job(name, prompt, schedule, skills, script, no_agent, context_from, workdir, deliver, repeat)
      when "list"     then JSON.dump("success" => true, "jobs" => @store.all.map { |j| summarize(j) })
      when "update"   then update_job(job_id, fields)
      when "pause"    then simple_update(job_id) { @store.pause(job_id) }
      when "resume"   then simple_update(job_id) { @store.resume(job_id) }
      when "remove"   then simple_update(job_id) { @store.remove(job_id) }
      when "run"      then run_job(job_id)
      else err("unknown action '#{action}'. Use: create, list, update, pause, resume, remove, run")
      end
    rescue ArgumentError => e
      err(e.message)
    end

    private

    def create_job(name, prompt, schedule, skills, script, no_agent, context_from, workdir, deliver, repeat)
      return err("name is required for create") if name.to_s.strip.empty?
      return err("prompt is required for create") if prompt.to_s.strip.empty? && !no_agent
      return err("schedule is required for create") if schedule.to_s.strip.empty?

      scan = Hermes::ThreatPatterns.first_threat_message("#{prompt}\n#{script}", scope: "strict")
      return err("Cron job refused: #{scan}") if scan

      missing = Array(context_from).reject { |id| @store.find(id) }
      return err("context_from job(s) not found: #{missing.join(', ')}") unless missing.empty?

      job = @store.create(
        name: name, prompt: prompt, schedule: schedule, skills: skills || [],
        script: script, no_agent: no_agent, context_from: context_from || [],
        workdir: workdir, deliver: deliver, repeat: repeat,
        created_in_cron: @in_cron,
      )
      JSON.dump("success" => true, "job_id" => job["id"],
                "enabled" => job["enabled"],
                "note" => (job["enabled"] ? nil : "Job created DISABLED (created inside a cron run — enable with resume)."),
                "next_run_at" => job["next_run_at"])
    end

    def update_job(job_id, fields)
      return err("job_id is required") if job_id.to_s.empty?
      return err("fields is required for update") unless fields.is_a?(Hash) && !fields.empty?

      allowed = %w[name prompt schedule deliver workdir skills]
      updates = fields.transform_keys(&:to_s).slice(*allowed)
      updates["schedule"] = Hermes::CronStore.parse_schedule(updates["schedule"]) if updates["schedule"]
      job = @store.update(job_id, **updates.transform_keys(&:to_sym))
      return err("job '#{job_id}' not found") unless job

      JSON.dump("success" => true, "job_id" => job_id, "next_run_at" => job["next_run_at"])
    end

    def simple_update(job_id)
      return err("job_id is required") if job_id.to_s.empty?

      result = yield
      return err("job '#{job_id}' not found") unless result

      JSON.dump("success" => true, "job_id" => job_id)
    end

    def run_job(job_id)
      return err("job_id is required") if job_id.to_s.empty?
      return err("job '#{job_id}' not found") unless @store.find(job_id)
      return err("no runner configured (run is driver-side in this context)") unless @runner

      result = @runner.call(@store.find(job_id))
      JSON.dump("success" => true, "job_id" => job_id, "result" => result.to_s[0, 2_000])
    end

    def summarize(job)
      job.slice("id", "name", "enabled", "state", "next_run_at", "last_run_at", "last_status", "deliver")
    end

    def err(message)
      JSON.dump("success" => false, "error" => message)
    end
  end
end
