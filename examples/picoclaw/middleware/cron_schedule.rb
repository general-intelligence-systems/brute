# frozen_string_literal: true

# CronSchedule — due-job firing + store persistence (picoclaw's checkJobs +
# ExecuteJob, adapted to the external systemd ticker).
#
# IN : loads the store, puts it in env[:metadata][:cron][:store] (shared with
#      the CronTool), fires due jobs: COMMAND jobs run through the exec tool
#      and their output is injected; MESSAGE jobs are injected as
#      "- name: message" lines in one user message.
# OUT: marks due jobs run (last_run_at, last_status, last_error), deletes
#      one-shots, disables expired at-jobs, persists the store — merging any
#      jobs the agent added mid-turn.
# Granularity is bounded by the timer cadence. Crash mid-turn => the job
# stays due and is retried next tick (at-least-once).
class CronSchedule
  def initialize(app, store:, exec_tool: nil)
    @app = app
    @store = store
    @exec_tool = exec_tool
  end

  def call(env)
    @store.load
    env[:metadata][:cron] = { store: @store }

    due = @store.due
    if due.any?
      results = due.map { |job| fire(job) }
      env[:messages] << Brute::Message.new(role: :user, content: due_message(results))
      env[:metadata][:cron][:due] = due.map { |j| j[:id] }
      complete(due, results)
    end

    @app.call(env)

    @store.save if @store.dirty? # the agent may have added/removed jobs mid-turn
    env
  end

  private

  # ExecuteJob port: command jobs run through the exec tool; message jobs
  # deliver their payload text.
  def fire(job)
    command = job.dig(:payload, :command).to_s
    return { job: job, status: "ok", text: "- #{job[:name]}: #{job.dig(:payload, :message)}" } if command.empty?

    if @exec_tool.nil?
      return { job: job, status: "error", text: "- #{job[:name]}: Error executing scheduled command: command execution is disabled" }
    end

    result = @exec_tool.call({ "action" => "run", "command" => command, "__channel" => "cli", "__chat_id" => "direct" })
    { job: job, status: "ok", text: "- #{job[:name]}: Scheduled command '#{command}' executed:\n#{result}" }
  rescue StandardError => e
    { job: job, status: "error", text: "- #{job[:name]}: Error executing scheduled command: #{e.message}" }
  end

  def due_message(results)
    <<~MSG
      The following scheduled jobs are due now. Execute each with your tools,
      then continue with any other heartbeat tasks:

      #{results.map { |r| r[:text] }.join("\n")}
    MSG
  end

  def complete(due, results)
    now = Time.now
    by_id = results.to_h { |r| [r[:job][:id], r] }
    due.each do |job|
      next unless @store.find(job[:id]) # the agent may have removed it

      result = by_id[job[:id]]
      job[:state][:last_run_at] = now.to_i
      job[:state][:last_status] = result ? result[:status] : "ok"
      job[:state].delete(:last_error) if result && result[:status] == "ok"
      job[:state][:last_error] = result[:text] if result && result[:status] == "error"
      if job[:delete_after_run]
        @store.remove(job[:id])
      else
        job[:state][:next_run_at] = @store.next_run(job[:schedule], from: now)
        job[:enabled] = false if job[:schedule][:kind].to_s == "at" && job[:state][:next_run_at].nil?
      end
    end
    @store.touch
    @store.save
  end
end
