# frozen_string_literal: true

require "json"

# cron — picoclaw `pkg/tools/cron.go` (CronTool).
#
# The agent-facing job manager. Channel context is fixed to cli/direct in this
# port (an internal channel), so the remote-channel ACLs always pass; command
# jobs still require tools.exec.enabled and honor tools.cron.allow_command
# (command_confirm=true override) — the GHSA-pv8c-p6jf-3fpp gates.
#
# Upstream quirk kept: `add` ignores the `name` param — the job name is the
# message truncated to 30 chars (the description says "for update or add" but
# addJob never reads it).
class CronTool < Brute::Tool
  description "Schedule, inspect, and update reminders, tasks, or system commands. \n" \
              "IMPORTANT: When user asks to be reminded or scheduled, you MUST call this tool. \n" \
              "Use 'at_seconds' for one-time reminders (e.g., 'remind me in 10 minutes' → at_seconds=600). \n" \
              "Use 'every_seconds' ONLY for recurring tasks (e.g., 'every 2 hours' → every_seconds=7200). \n" \
              "Use 'cron_expr' for complex recurring schedules. \n" \
              "Use 'command' to execute shell commands directly."
  params({
    "type" => "object",
    "properties" => {
      "action" => { "type" => "string", "enum" => %w[add list get update remove enable disable], "description" => "Action to perform. Use 'get' before editing and 'update' to change existing jobs without losing their payload. Remote channels can only list/get/update jobs for the current channel/chat_id." },
      "name" => { "type" => "string", "description" => "Optional job display name for update or add." },
      "message" => { "type" => "string", "description" => "The reminder/task message to display when triggered. If 'command' is used, this describes what the command does." },
      "command" => { "type" => "string", "description" => "Optional: Shell command to execute directly (e.g., 'df -h'). If set, the agent will run this command and report output instead of just showing the message. For update, omit to preserve the command or pass an empty string to clear it." },
      "command_confirm" => { "type" => "boolean", "description" => "Optional explicit confirmation flag for scheduling a shell command. Command execution must also be enabled via tools.cron.allow_command." },
      "at_seconds" => { "type" => "integer", "description" => "One-time reminder: seconds from now when to trigger (e.g., 600 for 10 minutes later). Use this for one-time reminders like 'remind me in 10 minutes'." },
      "every_seconds" => { "type" => "integer", "description" => "Recurring interval in seconds (e.g., 3600 for every hour). Use this ONLY for recurring tasks like 'every 2 hours' or 'daily reminder'." },
      "cron_expr" => { "type" => "string", "description" => "Cron expression for complex recurring schedules (e.g., '0 9 * * *' for daily at 9am). Use this for complex recurring schedules." },
      "job_id" => { "type" => "string", "description" => "Job ID (for get/update/remove/enable/disable)" },
    },
    "required" => ["action"],
  })

  CHANNEL = "cli"
  CHAT_ID = "direct"

  def initialize(store:, exec_enabled: true, allow_command: true, command_allowed_remotes: [])
    @store = store
    @exec_enabled = exec_enabled
    @allow_command = allow_command
    @command_allowed_remotes = command_allowed_remotes
  end

  def name = "cron"

  def execute(action: nil, **args)
    return "action is required" unless action.is_a?(String)

    case action
    when "add" then add_job(args)
    when "list" then list_jobs
    when "get" then get_job(args)
    when "update" then update_job(args)
    when "remove" then remove_job(args)
    when "enable" then enable_job(args, true)
    when "disable" then enable_job(args, false)
    else "unknown action: #{action}"
    end
  rescue StandardError => e
    warn("cron crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    e.message
  end

  private

  def add_job(args)
    message = args[:message]
    return "message is required for add" unless message.is_a?(String) && !message.empty?

    schedule = schedule_from(args)
    return "one of at_seconds, every_seconds, or cron_expr is required" if schedule.nil?
    return schedule[:error] if schedule[:error]

    command = args[:command].is_a?(String) ? args[:command] : ""
    unless command.empty?
      return "command execution is disabled" unless @exec_enabled
      return "command_confirm=true is required when allow_command is disabled" if !@allow_command && args[:command_confirm] != true
    end

    job = @store.add(name: truncate(message, 30), schedule: schedule, message: message,
                     command: command.empty? ? nil : command, channel: CHANNEL, chat_id: CHAT_ID)
    "Cron job added: #{job[:name]} (id: #{job[:id]})"
  end

  def list_jobs
    jobs = @store.jobs
    return "No scheduled jobs" if jobs.empty?

    out = +"Scheduled jobs:\n"
    jobs.each do |job|
      schedule = job[:schedule] || {}
      info =
        case schedule[:kind].to_s
        when "every" then "every #{schedule[:every_seconds].to_i}s"
        when "cron" then schedule[:expr].to_s
        when "at" then "one-time"
        else "unknown"
        end
      out << "- #{job[:name]} (id: #{job[:id]}, #{info})\n"
    end
    out
  end

  def get_job(args)
    job_id = args[:job_id]
    return "job_id is required for get" unless job_id.is_a?(String) && !job_id.empty?

    job = @store.find(job_id)
    return "Job #{job_id} not found" unless job

    JSON.generate(job)
  end

  def update_job(args)
    job_id = args[:job_id]
    return "job_id is required for update" unless job_id.is_a?(String) && !job_id.empty?

    job = @store.find(job_id)
    return "Job #{job_id} not found" unless job

    job = Marshal.load(Marshal.dump(job)) # cloneCronJob
    patches = 0

    if args.key?(:name)
      return "name must be a string" unless args[:name].is_a?(String)
      return "name cannot be empty" if args[:name].strip.empty?

      job[:name] = args[:name]
      patches += 1
    end

    if args.key?(:message)
      return "message must be a string" unless args[:message].is_a?(String)
      return "message cannot be empty" if args[:message].strip.empty?

      job[:payload][:message] = args[:message]
      patches += 1
    end

    if %i[at_seconds every_seconds cron_expr].any? { |k| args.key?(k) }
      schedule = schedule_patch(args)
      return schedule[:error] if schedule[:error]

      job[:schedule] = schedule
      job[:delete_after_run] = schedule[:kind] == "at"
      patches += 1
    end

    if args.key?(:command)
      return "command must be a string" unless args[:command].is_a?(String)
      return "command execution is disabled" unless @exec_enabled
      if !@allow_command && args[:command_confirm] != true
        return "command_confirm=true is required when allow_command is disabled"
      end

      job[:payload][:command] = args[:command] # empty string clears it (upstream)
      patches += 1
    end

    return "at least one update field is required" if patches.zero?

    @store.update(job)
    "Cron job updated:\n#{JSON.generate(@store.find(job_id))}"
  end

  def remove_job(args)
    job_id = args[:job_id]
    return "job_id is required for remove" unless job_id.is_a?(String) && !job_id.empty?

    return "Job #{job_id} not found" unless @store.find(job_id)

    @store.remove(job_id)
    "Cron job removed: #{job_id}"
  end

  def enable_job(args, flag)
    job_id = args[:job_id]
    return "job_id is required for enable/disable" unless job_id.is_a?(String) && !job_id.empty?

    job = @store.enable(job_id, flag)
    return "Job #{job_id} not found" unless job

    "Cron job '#{job[:name]}' #{flag ? "enabled" : "disabled"}"
  end

  # add: priority at_seconds > every_seconds > cron_expr; zero/empty values
  # count as absent (LLMs fill unused optionals with 0).
  def schedule_from(args)
    at = numeric_seconds(args[:at_seconds])
    every = numeric_seconds(args[:every_seconds])
    expr = args[:cron_expr].is_a?(String) ? args[:cron_expr] : nil

    return { kind: "at", at: Time.now.to_i + at } if at&.positive?
    return { kind: "every", every_seconds: every } if every&.positive?
    return { kind: "cron", expr: expr } if expr && !expr.empty?

    nil
  end

  # update: presence-based; invalid values are hard errors (positiveSeconds).
  def schedule_patch(args)
    schedule = nil
    if args.key?(:at_seconds)
      seconds = positive_seconds(args[:at_seconds])
      return { error: "at_seconds must be a positive integer" } if seconds.nil?

      schedule = { kind: "at", at: Time.now.to_i + seconds }
    end
    if args.key?(:every_seconds)
      seconds = positive_seconds(args[:every_seconds])
      return { error: "every_seconds must be a positive integer" } if seconds.nil?

      schedule = { kind: "every", every_seconds: seconds }
    end
    if args.key?(:cron_expr)
      expr = args[:cron_expr]
      return { error: "cron_expr must be a string" } unless expr.is_a?(String)

      schedule = { kind: "cron", expr: expr }
    end
    schedule || { error: "at least one update field is required" }
  end

  def numeric_seconds(value)
    case value
    when Integer then value
    when Float then value == value.truncate ? value.to_i : nil
    else nil
    end
  end

  def positive_seconds(value)
    seconds = numeric_seconds(value)
    seconds&.positive? ? seconds : nil
  end

  # utils.Truncate port: cut at max runes, append an ellipsis when cut.
  def truncate(str, max)
    return "" if max <= 0

    chars = str.chars
    chars.size > max ? "#{chars.first(max).join}..." : str
  end
end
