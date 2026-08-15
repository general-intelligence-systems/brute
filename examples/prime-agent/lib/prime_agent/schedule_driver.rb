# frozen_string_literal: true

require_relative "cron_store"

module PrimeAgent
  # ScheduleDriver — delivers scheduled prompts by RUNNING the agent.
  #
  # The port of prime-agent's daemon-side scheduler (AgentCronScheduler +
  # DaemonMode.runCronJob, core/cron-jobs.ts + modes/daemon/daemon-mode.ts),
  # adapted to this port's process model: there is no resident session, so a
  # due job is delivered as a fresh agent run whose task is the job's prompt.
  # Every delivery is effectively upstream's follow_up; steer/deferral are
  # resident-session concepts with no meaning here. Overlap protection and
  # missed-tick coalescing come from CronStore's claim ledger.
  #
  # One-shot mode (default): recover interrupted dispatches, run the initial
  # task, drain every currently-due job, exit — this is what the systemd
  # timer activates (README: Scheduled operation).
  #
  # Follow mode (BRUTE_FOLLOW=1): keep sleeping until the next due tick and
  # draining, for as long as any job has a future run — including jobs the
  # agent itself creates mid-run via rlm_heartbeat.
  class ScheduleDriver
    def initialize(store:, agent_factory:, sleeper: ->(seconds) { sleep(seconds) })
      @store = store
      @agent_factory = agent_factory
      @sleeper = sleeper
    end

    # Returns the last run's env (main.rb prints its final answer).
    def run(task, follow: false)
      @store.recover_interrupted
      env = nil
      env = start_run(task) unless task.to_s.empty?
      env = drain_due || env
      return env unless follow

      loop do
        next_run = @store.next_active_run_at
        break unless next_run # no future ticks: nothing left to follow

        @sleeper.call([next_run - Time.now.utc, 0].max)
        env = drain_due || env
      end
      env
    end

    private

    def start_run(prompt)
      @agent_factory.call.start(prompt)
    end

    # Claim and run every due job; a failing run is recorded with its error
    # and never blocks the remaining queue (upstream's onError + continue).
    def drain_due
      env = nil
      @store.claim_due.each do |dispatch|
        begin
          env = start_run(dispatch.job.prompt)
          @store.record_result(dispatch.id, outcome: "ran")
        rescue StandardError => error
          @store.record_result(dispatch.id, outcome: "ran", error: error)
        end
      end
      env
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/schedule_driver" do
  # Jobs are created with a `now` far in the past so their ticks are due
  # relative to the real clock (the driver claims with Time.now).
  PAST = Time.utc(2020, 1, 1)

  def setup(dir, prompts, failures: [])
    store = PrimeAgent::CronStore.new(File.join(dir, "scheduled-jobs.json"))
    factory = lambda do
      agent = Object.new
      agent.define_singleton_method(:start) do |prompt|
        prompts << prompt
        raise "run exploded" if failures.include?(prompt)

        { messages: prompt }
      end
      agent
    end
    [store, factory]
  end

  it "runs the initial task and no jobs when none are due" do
    Dir.mktmpdir do |dir|
      prompts = []
      store, factory = setup(dir, prompts)
      env = PrimeAgent::ScheduleDriver.new(store: store, agent_factory: factory).run("the task")
      prompts.should == ["the task"]
      env[:messages].should == "the task"
    end
  end

  it "drains due jobs after the initial task and records the result" do
    Dir.mktmpdir do |dir|
      prompts = []
      store, factory = setup(dir, prompts)
      store.create(prompt: "scheduled prompt", schedule_text: "in 30m", now: PAST)
      env = PrimeAgent::ScheduleDriver.new(store: store, agent_factory: factory).run("the task")
      prompts.should == ["the task", "scheduled prompt"]
      job = store.jobs.first
      job.run_count.should == 1
      job.status.should == "completed" # one-shot
      job.last_run_at.should.not.be.nil
      env[:messages].should == "scheduled prompt"
    end
  end

  it "leaves future jobs alone in one-shot mode" do
    Dir.mktmpdir do |dir|
      prompts = []
      store, factory = setup(dir, prompts)
      store.create(prompt: "not yet", schedule_text: "every 1h")
      PrimeAgent::ScheduleDriver.new(store: store, agent_factory: factory).run("the task")
      prompts.should == ["the task"]
      store.jobs.first.run_count.should == 0
    end
  end

  it "records a failing run's error and still drains the rest" do
    Dir.mktmpdir do |dir|
      prompts = []
      store, factory = setup(dir, prompts, failures: ["doomed"])
      store.create(prompt: "doomed", schedule_text: "in 30m", now: PAST)
      store.create(prompt: "fine", schedule_text: "in 30m", now: PAST)
      PrimeAgent::ScheduleDriver.new(store: store, agent_factory: factory).run(nil)
      prompts.should == %w[doomed fine]
      doomed = store.jobs.find { |job| job.prompt == "doomed" }
      doomed.last_error.should == "RuntimeError: run exploded"
      doomed.status.should == "completed"
      store.jobs.find { |job| job.prompt == "fine" }.run_count.should == 1
    end
  end

  it "recovers crashed claims before draining (no replay of an uncertain one-shot)" do
    Dir.mktmpdir do |dir|
      prompts = []
      store, factory = setup(dir, prompts)
      store.create(prompt: "maybe ran", schedule_text: "in 30m", now: PAST)
      store.claim_due # simulate the crash: claimed, never recorded
      PrimeAgent::ScheduleDriver.new(store: store, agent_factory: factory).run("the task")
      prompts.should == ["the task"]
      job = store.jobs.first
      job.last_error.should == PrimeAgent::CronStore::INTERRUPTED_ERROR
      job.status.should == "completed"
    end
  end

  it "follow mode sleeps to the next tick and exits when no future runs remain" do
    Dir.mktmpdir do |dir|
      prompts = []
      sleeps = []
      store, factory = setup(dir, prompts)
      store.create(prompt: "due now", schedule_text: "in 30m", now: PAST)
      driver = PrimeAgent::ScheduleDriver.new(
        store: store, agent_factory: factory, sleeper: ->(seconds) { sleeps << seconds },
      )
      driver.run(nil, follow: true)
      prompts.should == ["due now"]
      sleeps.should == [] # next_active_run_at was nil right after the drain
    end
  end
end
