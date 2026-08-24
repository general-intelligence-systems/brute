# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # Pub/sub registry for agent lifecycle hooks, subscribed on the builder:
  #
  #   Brute.agent
  #     .use(Brute::Middleware::MaxIterations)
  #     .run(->(env) { env[:messages].assistant("done") })
  #     .on(:before_llm) { |env| ... }
  #     .on(:approve_tool) { |_env, call| call[:name] != "exec" }
  #
  # Every subscriber is called with the turn env first, followed by whatever
  # extras that event carries. A block that only wants the env can take one
  # argument and ignore the rest.
  #
  # Emission points and payloads:
  #
  #   :turn_start, :turn_end  → the turn env (AgentPipeline#start; turn_end
  #                             fires from an ensure, so it also fires on
  #                             error)
  #   :turn_duration          → env, started, finished: the turn's work is
  #                             this event's block
  #   :middleware_added       → an empty env, then the middleware and every
  #                             argument `use` was given (fires at build time,
  #                             so only subscribers registered before the `use`
  #                             see it)
  #   :enter                  → env, the middleware instance, before the
  #                             layer does anything
  #   :duration               → env, started, finished, the middleware
  #                             instance: the layer's work is this event's
  #                             block, so it reports how long that took
  #   :exit                   → env, the middleware instance, marking the
  #                             layer done (from an ensure, so it fires on
  #                             error too)
  #   :before_llm, :after_llm → the turn env, around every LLM call
  #   :llm_duration           → env, started, finished: the provider call is
  #                             this event's block
  #   :llm_failure            → the turn env, when the LLM call raises; the
  #                             completion middleware then emits one of
  #                             :faraday_error, :open_router_server_error or
  #                             :standard_error with the exception as an extra
  #   :before_tool            → env, call env {name:, arguments:, result:,
  #                             denied:, events:, metadata:, turn_env:} —
  #                             mutate :arguments to rewrite the call, or set
  #                             :result to answer it without executing
  #   :approve_tool           → env, call env — set :denied to true to deny
  #                             the call, or to a String to deny it with that
  #                             message
  #   :tool_duration          → env, started, finished, call env: the tool's
  #                             own execution is this event's block, so a
  #                             skipped or denied call never fires it
  #   :after_tool             → env, call env — mutate :result
  #
  # Subscribers run inline (tool events may fire from parallel threads).
  # Exceptions propagate to the caller — layers that want fail-open semantics
  # rescue in their own subscriber.
  # Include this in anything that emits or subscribes and the event names are
  # first class there: ENTER_EVENT rather than Brute::Hooks::ENTER_EVENT.
  # The registry itself is Hooks::Registry, and Brute::Hooks.new builds one.
  module Hooks
    TURN_START_EVENT = :turn_start
    TURN_DURATION_EVENT = :turn_duration
    TURN_END_EVENT = :turn_end
    MIDDLEWARE_ADDED_EVENT = :middleware_added
    ENTER_EVENT = :enter
    DURATION_EVENT = :duration
    EXIT_EVENT = :exit
    BEFORE_LLM_EVENT = :before_llm
    LLM_DURATION_EVENT = :llm_duration
    AFTER_LLM_EVENT = :after_llm
    LLM_FAILURE_EVENT = :llm_failure
    FARADAY_ERROR_EVENT = :faraday_error
    OPEN_ROUTER_SERVER_ERROR_EVENT = :open_router_server_error
    STANDARD_ERROR_EVENT = :standard_error
    BEFORE_TOOL_EVENT = :before_tool
    APPROVE_TOOL_EVENT = :approve_tool
    TOOL_DURATION_EVENT = :tool_duration
    AFTER_TOOL_EVENT = :after_tool

    # The pub/sub registry a pipeline owns; `use` and `run` bind an emit to it.
    class Registry
      def initialize
        @subscribers = Hash.new { |hash, key| hash[key] = [] }
      end

      def on(event, &block)
        @subscribers[event.to_sym] << block
        self
      end

      # Fire an event. An emitter announces; it answers nothing, and what a
      # subscriber's block happens to evaluate to is not a signal. A layer
      # that wants to take part in a turn does it by mutating what it was
      # handed, never by returning something.
      #
      # Given a block, the event is timed instead: the block is the work, and
      # subscribers fire once it is done, called as
      # `|env, started, finished, *extras|` rather than `|env, *extras|`.
      # Both stamps are monotonic, so a clock adjustment mid-turn cannot
      # produce a negative duration.
      #
      # The block is the work and nothing more: `emit` answers nothing in
      # either form, so a caller that needs the work's value takes it inside
      # the block.
      #
      #   result = nil
      #   emit(DURATION_EVENT, env, self) { result = @app.call(env) }
      #   # => .on(DURATION_EVENT) { |env, started, finished, layer| ... }
      #
      # Subscribers fire from an ensure, so work that raises is still timed
      # and still reported before the exception carries on up.
      def emit(event, env, *extras, &block)
        unless block
          @subscribers[event.to_sym].each { |subscriber| subscriber.call(env, *extras) }
          return nil
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          block.call
        ensure
          finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @subscribers[event.to_sym].each { |subscriber| subscriber.call(env, started, finished, *extras) }
        end

        nil
      end

      def any?(event) = @subscribers[event.to_sym].any?
    end

    def self.new(...) = Registry.new(...)
  end
end

__END__

describe "brute/hooks" do
  it "emits to subscribers in registration order" do
    hooks = Brute::Hooks.new
    seen = []
    hooks.on(:before_llm) { |env| seen << "a#{env}" }
    hooks.on(:before_llm) { |env| seen << "b#{env}" }
    hooks.emit(:before_llm, 1)
    seen.should == ["a1", "b1"]
  end

  it "answers nothing: a subscriber takes part by mutating, not by returning" do
    hooks = Brute::Hooks.new
    hooks.on(:approve_tool) { |_env, call| call[:denied] = true }

    call = {}
    hooks.emit(:approve_tool, {}, call).should.be.nil
    call[:denied].should.be.true
  end

  it "hands every subscriber the env first and the extras after" do
    hooks = Brute::Hooks.new
    seen = []
    hooks.on(:after_tool) { |env, call| seen << [env, call] }
    hooks.emit(:after_tool, :turn, :call)
    seen.should == [[:turn, :call]]
  end

  it "times a block, hands subscribers start and finish, and reports even when the work raises" do
    seen = []
    hooks = Brute::Hooks.new
    hooks.on(:exit) { |env, started, finished, subject| seen << [env, started, finished, subject] }

    ran = nil
    hooks.emit(:exit, :env, :layer) { ran = :work_result }.should.be.nil
    ran.should == :work_result
    seen.size.should == 1
    env, started, finished, subject = seen.first
    env.should == :env
    subject.should == :layer
    (finished - started).should.be >= 0

    # Work that raises is still timed and still reported.
    should.raise(RuntimeError) { hooks.emit(:exit, :env, :layer) { raise "boom" } }
    seen.size.should == 2

    # Without a block it stays a point event: no timing argument.
    args = []
    hooks2 = Brute::Hooks.new
    hooks2.on(:exit) { |*received| args << received }
    hooks2.emit(:exit, :env, :layer)
    args.should == [[:env, :layer]]
  end

  it "answers any? and stays chainable" do
    hooks = Brute::Hooks.new
    hooks.any?(:turn_start).should.be.false
    hooks.on(:turn_start) { nil }.should.equal?(hooks)
    hooks.any?(:turn_start).should.be.true
  end
end
