# frozen_string_literal: true

require_relative "../autonomous"
require_relative "../compaction"
require_relative "../goal"

module PrimeAgent
  module Middleware
    # Autonomous — per-turn middleware (outside the loop, INSIDE
    # Middleware::Goal). The port of prime-agent's autonomous continuation
    # policy (core/autonomous.ts + agent-session.ts _getContinuationMessages).
    #
    # When enabled, a turn never simply ends: the quality gates run, and on a
    # gate failure (or with no gates, while "terminal evidence" is missing) a
    # continuation user message is appended and another turn runs — until a
    # gate passes or a limit is hit (maxContinuations 3 / maxTurns 12 /
    # maxTokens 80_000 / 30 minutes; gates: 3 retries, 5-minute timeout,
    # 6000-char output). A failed gate is not rerun while the git worktree
    # snapshot is unchanged. Never continues after an error turn.
    #
    # Two port adaptations:
    #  - the goal gets first refusal (upstream's continuation ordering): when
    #    a thread goal is active, this middleware does not continue — it
    #    reads <goal_store_path> (goal.json) each turn to decide;
    #  - token accounting is estimated (chars/4 over the turn's new
    #    messages): brute's transport carries no per-message usage, and
    #    cache-read exclusion is moot in estimate mode.
    #
    # RLM children are force-disabled upstream; here KernelAgents simply
    # never include this middleware in their child pipelines.
    class Autonomous
      def initialize(app, enabled: false, cwd: Dir.pwd, goal_store_path: nil,
                     gates: [], continuation_prompt: nil, **limits)
        @app = app
        @cwd = cwd
        @goal_store_path = goal_store_path
        @state = PrimeAgent::Autonomous.build_state(
          enabled: enabled, gates: gates, continuation_prompt: continuation_prompt, **limits,
        )
        @accounted_cursor = 0
      end

      def call(env)
        return @app.call(env) unless @state.enabled

        run_turn(env)
        loop do
          account_turn(env)
          break if goal_active?

          decision = PrimeAgent::Autonomous.should_continue(@state, error_turn: false, cwd: @cwd)
          break unless decision[:continue]

          @state.continuations_used += 1
          env[:messages] << Brute::Message.new(role: :user, content: continuation_text)
          run_turn(env)
        end
        env
      end

      private

      # A continuation is the gate-failure message when a gate failed this
      # check, else the (default) continuation prompt (nextAutonomousContinuation).
      def continuation_text
        failure = @state.last_gate_failure
        return @state.continuation_prompt unless failure

        PrimeAgent::Autonomous.build_gate_failure_continuation(failure, @state.gate_max_retries)
      end

      # Never continue after an error turn (upstream: stopReason error/aborted
      # short-circuits the policy) — the error propagates out of the run.
      def run_turn(env)
        @app.call(env)
      end

      def goal_active?
        return false unless @goal_store_path

        PrimeAgent::Goal.load_state(@goal_store_path).active?
      end

      # addAutonomousUsage: one turn per iteration; the token delta counts
      # the turn's new messages (estimate mode — see class comment). The
      # cursor re-anchors when compaction shrinks the log.
      def account_turn(env)
        messages = env[:messages]
        from = @accounted_cursor
        from = messages.length if from > messages.length
        delta = messages[from..] || []
        @accounted_cursor = messages.length

        @state.turns_used += 1
        @state.tokens_used += delta.reject { |message| message.role == :system }
                                   .sum { |message| PrimeAgent::Compaction.estimate_tokens(message) }
      end
    end
  end
end

__END__

describe "prime_agent/middleware/autonomous" do
  require "brute/messages"
  require "tmpdir"

  def build(app, dir, **opts)
    PrimeAgent::Middleware::Autonomous.new(app, cwd: dir, **opts)
  end

  def fresh_env
    log = Brute.log
    log.user("task")
    { messages: log }
  end

  it "passes through once when disabled" do
    Dir.mktmpdir do |dir|
      calls = 0
      app = ->(env) { calls += 1; env[:messages].assistant("done"); env }
      build(app, dir, enabled: false).call(fresh_env)
      calls.should == 1
    end
  end

  it "continues with the default prompt until maxContinuations, then stops" do
    Dir.mktmpdir do |dir|
      calls = 0
      app = ->(env) { calls += 1; env[:messages].assistant("working"); env }
      env = fresh_env
      build(app, dir, enabled: true).call(env)
      calls.should == 4 # initial turn + 3 continuations
      continuations = env[:messages].select { |m| m.role == :user && m.content.include?("autonomous mode") }
      continuations.length.should == 3
      continuations.first.content.should ==
        PrimeAgent::Autonomous::DEFAULT_CONTINUATION_PROMPT
    end
  end

  it "stops when the gate passes and continues with the gate-failure message when it fails" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "gate-ok")
      gate = "test -f #{marker}"
      calls = 0
      app = lambda do |env|
        calls += 1
        File.write(marker, "ok") if calls == 2 # the agent fixes the repo on turn 2
        env[:messages].assistant("working")
        env
      end
      env = fresh_env
      build(app, dir, enabled: true, gates: [gate]).call(env)
      calls.should == 2
      failure_messages = env[:messages].select { |m| m.content.to_s.include?("Autonomous quality gate failed") }
      failure_messages.length.should == 1
      failure_messages.first.content.should.include "(attempt 1/3)"
      failure_messages.first.content.should.include "Timestamp:"
    end
  end

  it "does not rerun a failed gate while the workspace is unchanged" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "README"), "init")
      setup_ok = system("git", "-C", dir, "init", "-q") &&
                 system("git", "-C", dir, "add", "-A") &&
                 system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
      raise "git setup failed" unless setup_ok

      calls = 0
      app = ->(env) { calls += 1; env[:messages].assistant("nothing changes"); env }
      env = fresh_env
      build(app, dir, enabled: true, gates: ["false"]).call(env)
      calls.should == 4 # 1 + 3 continuations; retry_exhausted and the limit coincide
      texts = env[:messages].map(&:content).join
      texts.should.include "not rerun: workspace unchanged since previous failed gate"
    end
  end

  it "defers to an active goal (first refusal)" do
    Dir.mktmpdir do |dir|
      goal_path = File.join(dir, "goal.json")
      PrimeAgent::Goal.create_in_store(goal_path, objective: "the goal drives")
      calls = 0
      app = ->(env) { calls += 1; env[:messages].assistant("working"); env }
      build(app, dir, enabled: true, goal_store_path: goal_path).call(fresh_env)
      calls.should == 1 # autonomous never continues while the goal is active
    end
  end
end
