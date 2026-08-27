# frozen_string_literal: true

require "bundler/setup"
require "delegate"
require "securerandom"

require "brute"

module Brute
  # Pub/sub registry for agent lifecycle hooks, subscribed on the builder:
  #
  #   Brute.agent
  #     .use(Brute::Middleware::MaxIterations)
  #     .run(->(env) { env[:messages].assistant("done") })
  #     .on(:llm_start) { |env| ... }
  #     .on(:tool_approve) { |_env, call| call[:name] != "exec" }
  #
  module Hooks
    TURN_START_EVENT = :turn_start
    TURN_DURATION_EVENT = :turn_duration
    TURN_END_EVENT = :turn_end
    TURN_FAILURE_EVENT = :turn_failure
    MIDDLEWARE_ADDED_EVENT = :middleware_added
    MIDDLEWARE_START_EVENT = :middleware_start
    MIDDLEWARE_DURATION_EVENT = :middleware_duration
    MIDDLEWARE_END_EVENT = :middleware_end
    MIDDLEWARE_FAILURE_EVENT = :middleware_failure
    LLM_START_EVENT = :llm_start
    LLM_DURATION_EVENT = :llm_duration
    LLM_END_EVENT = :llm_end
    LLM_FAILURE_EVENT = :llm_failure
    FARADAY_ERROR_EVENT = :faraday_error
    OPEN_ROUTER_SERVER_ERROR_EVENT = :open_router_server_error
    STANDARD_ERROR_EVENT = :standard_error
    COMPACT_START_EVENT = :compact_start
    COMPACT_DURATION_EVENT = :compact_duration
    COMPACT_END_EVENT = :compact_end
    COMPACT_FAILURE_EVENT = :compact_failure
    CONTENT_EVENT = :content
    REASONING_EVENT = :reasoning
    TOOL_CALLS_EVENT = :tool_calls
    TOOL_START_EVENT = :tool_start
    TOOL_APPROVE_EVENT = :tool_approve
    TOOL_DURATION_EVENT = :tool_duration
    TOOL_END_EVENT = :tool_end
    TOOL_FAILURE_EVENT = :tool_failure

    # The env, wrapped, for as long as one call lasts. Everything emitted
    # through it carries that call's id, and a call opened inside another
    # delegates to it -- so the wrapper is the parent and unwrapping ends the
    # call. It is still the env: SimpleDelegator forwards the rest.
    class Trace < SimpleDelegator
      attr_reader :id, :hooks

      def initialize(env, hooks: nil, id: SecureRandom.uuid)
        super(env)
        if hooks
          @hooks = hooks
        elsif env.is_a?(Trace)
          @hooks = env.hooks
        end
        @id = id
      end

      def current_trace = self

      def emit(event, *extras, &work) = @hooks.emit(
        event,
        self,
        *extras,
        @id,
        &work
      )

      def emit_trace(&block) = self.class.new(self).tap(&block).then { |trace| trace.__getobj__ }
    end


    # The pub/sub registry a pipeline owns; `use` and `run` bind an emit to it.
    class Registry
      def initialize
        @subscribers = Hash.new { |hash, key| hash[key] = [] }
      end

      def on(event, &block)
        @subscribers[event.to_sym] << block
        self
      end

      # The block is the work and nothing more: `emit` answers nothing in
      # either form, so a caller that needs the work's value takes it inside
      # the block.
      #
      #   result = nil
      #   emit(MIDDLEWARE_DURATION_EVENT, env, self) { result = @app.call(env) }
      #   # => .on(MIDDLEWARE_DURATION_EVENT) { |env, started, finished, layer| ... }
      #
      # Subscribers fire from an ensure, so work that raises is still timed
      # and still reported before the exception carries on up.
      def emit(event, env, *extras, &block)
        if block
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            block.call
          ensure
            finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            @subscribers[event.to_sym].each { |subscriber| subscriber.call(
              env,
              started,
              finished,
              *extras,
            ) }
          end
        else
          @subscribers[event.to_sym].each { |subscriber| subscriber.call(env, *extras) }
        end

        nil
      end

      def any?(event) = @subscribers[event.to_sym].any?
    end
  end
end

__END__

describe "brute/hooks" do
  it "emits to subscribers in registration order" do
    hooks = Brute::Hooks::Registry.new
    seen = []
    hooks.on(:llm_start) { |env| seen << "a#{env}" }
    hooks.on(:llm_start) { |env| seen << "b#{env}" }
    hooks.emit(:llm_start, 1)
    seen.should == ["a1", "b1"]
  end

  it "answers nothing: a subscriber takes part by mutating, not by returning" do
    hooks = Brute::Hooks::Registry.new
    hooks.on(:tool_approve) { |_env, call| call[:denied] = true }

    call = {}
    hooks.emit(:tool_approve, {}, call).should.be.nil
    call[:denied].should.be.true
  end

  it "hands every subscriber the env first and the extras after" do
    hooks = Brute::Hooks::Registry.new
    seen = []
    hooks.on(:tool_end) { |env, call| seen << [env, call] }
    hooks.emit(:tool_end, :turn, :call)
    seen.should == [[:turn, :call]]
  end

  it "times a block, hands subscribers start and finish, and reports even when the work raises" do
    seen = []
    hooks = Brute::Hooks::Registry.new
    hooks.on(:middleware_end) { |env, started, finished, subject| seen << [env, started, finished, subject] }

    ran = nil
    hooks.emit(:middleware_end, :env, :layer) { ran = :work_result }.should.be.nil
    ran.should == :work_result
    seen.size.should == 1
    env, started, finished, subject = seen.first
    env.should == :env
    subject.should == :layer
    (finished - started).should.be >= 0

    # Work that raises is still timed and still reported.
    should.raise(RuntimeError) { hooks.emit(:middleware_end, :env, :layer) { raise "boom" } }
    seen.size.should == 2

    # Without a block it stays a point event: no timing argument.
    args = []
    hooks2 = Brute::Hooks::Registry.new
    hooks2.on(:middleware_end) { |*received| args << received }
    hooks2.emit(:middleware_end, :env, :layer)
    args.should == [[:env, :layer]]
  end

  it "answers any? and stays chainable" do
    hooks = Brute::Hooks::Registry.new
    hooks.any?(:turn_start).should.be.false
    hooks.on(:turn_start) { nil }.should.equal?(hooks)
    hooks.any?(:turn_start).should.be.true
  end
end
