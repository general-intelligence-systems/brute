# frozen_string_literal: true

require_relative "../compaction"
require_relative "../goal"

module PrimeAgent
  module Middleware
    # Goal — per-turn middleware (outside the loop). The port of prime-agent's
    # persistent thread goal (core/goals.ts + agent-session.ts goal wiring).
    #
    # While a goal is active, the model may not idle: after each turn this
    # middleware appends a <goal_context> user message (ported verbatim from
    # goals.ts) and runs another turn. The loop ends when the kernel's
    # `goal.complete` request lands, the goal is paused/completed externally,
    # or the token budget flips it to budget_limited — which injects
    # upstream's wrap-up prompt for exactly one final turn.
    #
    # Bridges (the port's file equivalents of upstream's host bridge):
    #  - state:  <store_path> (goal.json) — read/written here, read directly
    #    by the kernel's `goal.get`;
    #  - requests: <request_path> (goal_request.json) — `goal.create` /
    #    `goal.complete` from the kernel, drained at each turn boundary
    #    (never mid-cell). A create while a goal is pending edits the
    #    objective in place and the next continuation uses the
    #    objective_updated prompt (upstream's /goal-while-active path).
    #
    # Usage accounting: upstream counts exact input+output per assistant
    # message; brute's transport carries no per-message usage, so this port
    # estimates (chars/4 over the turn's new messages — the same estimator
    # compaction uses). A compaction mid-run re-anchors the cursor, like
    # upstream's usage re-anchoring after a compaction.
    #
    # Ordering: placed OUTSIDE Middleware::Autonomous — the goal gets first
    # refusal every turn (upstream's continuation ordering), and Autonomous
    # defers while a goal is active.
    class Goal
      PENDING_STATUSES = %w[active paused budget_limited].freeze

      def initialize(app, store_path:, request_path:, enabled: true)
        @app = app
        @store_path = store_path
        @request_path = request_path
        @enabled = enabled
        @accounted_cursor = 0
        @last_tick = nil
        @objective_updated_pending = false
      end

      def call(env)
        return @app.call(env) unless @enabled

        drain_requests
        run_turn(env)
        loop do
          # Account the turn that just ran BEFORE draining requests, so a
          # goal completed mid-turn still has its final turn's usage
          # preserved (upstream accounts at message_end; the complete drains
          # later).
          state = PrimeAgent::Goal.load_state(@store_path)
          state = account_usage(env, state) if state.active?

          drain_requests
          state = PrimeAgent::Goal.load_state(@store_path)
          break unless state.active?

          if state.token_budget && state.tokens_used >= state.token_budget
            state = save(state.with(status: "budget_limited", last_reason: "budget_limit",
                                    updated_at: now_iso))
            append_goal_context(env, state, "budget_limit")
            run_turn(env) # exactly one wrap-up turn
            drain_requests
            break
          end

          kind = @objective_updated_pending ? "objective_updated" : "continuation"
          @objective_updated_pending = false
          append_goal_context(env, state, kind)
          save(state.with(continuations_used: state.continuations_used + 1, updated_at: now_iso))
          run_turn(env)
        end
        env
      end

      private

      def run_turn(env)
        @app.call(env)
      rescue StandardError => error
        state = PrimeAgent::Goal.load_state(@store_path)
        if state.objective && PENDING_STATUSES.include?(state.status)
          save(state.with(status: "error", last_error: "#{error.class}: #{error.message}",
                          updated_at: now_iso))
        end
        raise
      end

      def append_goal_context(env, state, kind)
        env[:messages] << Brute::Message.new(
          role: :user,
          content: PrimeAgent::Goal.context_message(state, kind),
        )
      end

      # Usage accounting: exact when the provider reports usage (upstream's
      # goalTokenDeltaForUsage: input+output per LLM call, summed via
      # UsageAttribution's usage_totals), chars/4 estimate otherwise. The
      # estimate cursor re-anchors (without double counting) when compaction
      # shrinks the log; once real usage flows it wins — the estimate cursor
      # never runs.
      def account_usage(env, state)
        messages = env[:messages]
        totals = env[:metadata] && env[:metadata][:usage_totals]
        tokens =
          if totals
            seen = @usage_seen ||= 0
            current = totals[:input_sum] + totals[:output_sum]
            @usage_seen = current
            current - seen
          else
            from = @accounted_cursor
            from = messages.length if from > messages.length
            delta = messages[from..] || []
            @accounted_cursor = messages.length
            delta.reject { |message| message.role == :system }
                 .sum { |message| PrimeAgent::Compaction.estimate_tokens(message) }
          end
        now = Time.now.utc
        elapsed = @last_tick ? (now - @last_tick).round : 0
        @last_tick = now
        return state if tokens.zero? && elapsed.zero?

        save(state.with(tokens_used: state.tokens_used + tokens,
                        time_used_seconds: state.time_used_seconds + elapsed,
                        updated_at: now.iso8601))
      end

      def drain_requests
        return unless File.exist?(@request_path)

        request =
          begin
            JSON.parse(File.read(@request_path))
          rescue JSON::ParserError
            nil
          end
        File.delete(@request_path)
        return unless request.is_a?(Hash)

        case request["action"]
        when "create" then apply_create(request)
        when "complete" then apply_complete
        end
      rescue ArgumentError
        nil # an invalid hand-written request is dropped, never fatal
      end

      def apply_create(request)
        objective = PrimeAgent::Goal.validate_objective(request["objective"].to_s)
        budget = PrimeAgent::Goal.validate_budget(request["token_budget"])
        state = PrimeAgent::Goal.load_state(@store_path)
        if state.objective && PENDING_STATUSES.include?(state.status)
          save(state.with(objective: objective, token_budget: budget, updated_at: now_iso))
          @objective_updated_pending = true
        else
          PrimeAgent::Goal.create_in_store(@store_path, objective: objective, token_budget: budget)
        end
      end

      def apply_complete
        state = PrimeAgent::Goal.load_state(@store_path)
        return if state.objective.nil? || state.status == "idle"

        save(state.with(status: "complete", updated_at: now_iso))
      end

      def save(state)
        PrimeAgent::Goal.save_state(@store_path, state)
      end

      def now_iso
        Time.now.utc.iso8601
      end
    end
  end
end

__END__

describe "prime_agent/middleware/goal" do
  require "brute/messages"
  require "tmpdir"

  def build(app, dir, enabled: true)
    PrimeAgent::Middleware::Goal.new(
      app,
      store_path: File.join(dir, "goal.json"),
      request_path: File.join(dir, "goal_request.json"),
      enabled: enabled,
    )
  end

  def env_with(messages)
    log = Brute.log
    messages.each { |role, content| log << Brute::Message.new(role: role, content: content) }
    { messages: log }
  end

  it "passes through once when no goal exists" do
    Dir.mktmpdir do |dir|
      calls = 0
      app = ->(env) { calls += 1; env[:messages].assistant("done"); env }
      env = env_with([[:user, "task"]])
      build(app, dir).call(env)
      calls.should == 1
      PrimeAgent::Goal.load_state(File.join(dir, "goal.json")).status.should == "idle"
    end
  end

  it "re-prompts until the kernel's goal.complete request lands" do
    Dir.mktmpdir do |dir|
      PrimeAgent::Goal.create_in_store(File.join(dir, "goal.json"), objective: "ship it")
      calls = 0
      app = lambda do |env|
        calls += 1
        env[:messages].assistant("working #{calls}")
        File.write(File.join(dir, "goal_request.json"), JSON.generate("action" => "complete")) if calls == 2
        env
      end
      env = env_with([[:user, "task"]])
      build(app, dir).call(env)

      calls.should == 2
      continuations = env[:messages].select { |m| m.content.to_s.include?("<goal_context>") }
      continuations.length.should == 1
      continuations.first.role.should == :user
      continuations.first.content.should.include "Continue working toward the active thread goal."
      continuations.first.content.should.include "ship it"
      PrimeAgent::Goal.load_state(File.join(dir, "goal.json")).status.should == "complete"
    end
  end

  it "flips to budget_limited, injects the wrap-up once, and stops" do
    Dir.mktmpdir do |dir|
      PrimeAgent::Goal.create_in_store(File.join(dir, "goal.json"),
                                       objective: "migrate", token_budget: 5)
      calls = 0
      app = lambda do |env|
        calls += 1
        env[:messages].assistant("x" * 400) # ~100 estimated tokens per turn
        env
      end
      env = env_with([[:user, "task"]])
      build(app, dir).call(env)

      calls.should == 2 # initial turn + the single wrap-up turn
      state = PrimeAgent::Goal.load_state(File.join(dir, "goal.json"))
      state.status.should == "budget_limited"
      state.tokens_used.should.be >= 5
      env[:messages].count { |m| m.content.to_s.include?("goal_context") }.should == 1
      env[:messages].find { |m| m.content.to_s.include?("goal_context") }.content
        .should.include "Do not start new substantive work."
    end
  end

  it "uses the objective_updated prompt when a create arrives while the goal is active" do
    Dir.mktmpdir do |dir|
      PrimeAgent::Goal.create_in_store(File.join(dir, "goal.json"), objective: "old objective")
      calls = 0
      app = lambda do |env|
        calls += 1
        env[:messages].assistant("working")
        if calls == 1
          File.write(File.join(dir, "goal_request.json"),
                     JSON.generate("action" => "create", "objective" => "new objective"))
        elsif calls == 2
          File.write(File.join(dir, "goal_request.json"), JSON.generate("action" => "complete"))
        end
        env
      end
      env = env_with([[:user, "task"]])
      build(app, dir).call(env)

      state = PrimeAgent::Goal.load_state(File.join(dir, "goal.json"))
      state.status.should == "complete"
      env[:messages].map(&:content).join.should.include "The active thread goal objective was edited by the user."
      env[:messages].map(&:content).join.should.include "new objective"
    end
  end

  it "counts exact provider usage toward the budget when reported" do
    Dir.mktmpdir do |dir|
      PrimeAgent::Goal.create_in_store(File.join(dir, "goal.json"),
                                       objective: "metered", token_budget: 500)
      calls = 0
      app = lambda do |env|
        calls += 1
        (env[:metadata] ||= {})[:usage_totals] = {
          calls: calls, input_sum: 100 * calls, output_sum: 40 * calls,
          cache_read_sum: 0, cache_write_sum: 0, total_sum: 140 * calls,
        }
        env[:messages].assistant("working")
        File.write(File.join(dir, "goal_request.json"), JSON.generate("action" => "complete")) if calls == 2
        env
      end
      env = env_with([[:user, "task"]])
      build(app, dir).call(env)

      state = PrimeAgent::Goal.load_state(File.join(dir, "goal.json"))
      state.tokens_used.should == 280 # 140 per turn — exact, not estimated
      state.status.should == "complete"
    end
  end

  it "marks the goal error when a turn raises, and re-raises" do
    Dir.mktmpdir do |dir|
      PrimeAgent::Goal.create_in_store(File.join(dir, "goal.json"), objective: "risky")
      app = ->(_env) { raise "provider exploded" }
      env = env_with([[:user, "task"]])
      lambda { build(app, dir).call(env) }.should.raise(RuntimeError)
      state = PrimeAgent::Goal.load_state(File.join(dir, "goal.json"))
      state.status.should == "error"
      state.last_error.should.include "provider exploded"
    end
  end
end
