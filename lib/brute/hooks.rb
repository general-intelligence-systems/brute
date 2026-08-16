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
  #     .on(:approve_tool) { |call| call[:name] != "exec" }
  #
  # Emission points and payloads:
  #
  #   :turn_start, :turn_end  → the turn env (AgentPipeline#start; turn_end
  #                             fires from an ensure, so it also fires on error)
  #   :before_llm, :after_llm → the turn env, around every LLM call
  #   :before_tool            → call env {name:, arguments:, result:, events:,
  #                             metadata:, turn_env:} — mutate :arguments to
  #                             rewrite the call, or set :result (or return a
  #                             value) to skip execution entirely ("respond")
  #   :approve_tool           → call env — a false return denies the call; a
  #                             String return denies it with that message
  #   :after_tool             → call env — mutate :result
  #
  # Subscribers run inline (tool events may fire from parallel threads).
  # Exceptions propagate to the caller — layers that want fail-open semantics
  # rescue in their own subscriber.
  class Hooks
    EVENTS = %i[turn_start turn_end before_llm after_llm before_tool approve_tool after_tool].freeze

    def initialize
      @subscribers = Hash.new { |hash, key| hash[key] = [] }
    end

    def on(event, &block)
      @subscribers[event.to_sym] << block
      self
    end

    # Fire an event; returns every subscriber's raw result (nils and false
    # included — the deny contract distinguishes them).
    def emit(event, payload)
      @subscribers[event.to_sym].map { |subscriber| subscriber.call(payload) }
    end

    def any?(event) = @subscribers[event.to_sym].any?
  end
end

__END__

describe "brute/hooks" do
  it "emits to subscribers in registration order" do
    hooks = Brute::Hooks.new
    seen = []
    hooks.on(:before_llm) { |p| seen << "a#{p}" }
    hooks.on(:before_llm) { |p| seen << "b#{p}" }
    hooks.emit(:before_llm, 1)
    seen.should == ["a1", "b1"]
  end

  it "returns raw results, false included (deny contract)" do
    hooks = Brute::Hooks.new
    hooks.on(:approve_tool) { |_call| false }
    hooks.emit(:approve_tool, {}).should == [false]
  end

  it "answers any? and stays chainable" do
    hooks = Brute::Hooks.new
    hooks.any?(:turn_start).should.be.false
    hooks.on(:turn_start) { nil }.should.equal?(hooks)
    hooks.any?(:turn_start).should.be.true
  end
end
