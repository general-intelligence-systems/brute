# frozen_string_literal: true

require "bundler/setup"
require "brute"

require "securerandom"
require "async"

module Brute
  module Loop
    # A first-class work object with identity, state, result/error capture,
    # optional sub-queue, and cancellation.
    #
    # Users subclass Step and override #perform(task). The framework calls
    # #call(task) which owns the state machine — subclasses never touch
    # state transitions directly.
    #
    # State machine:
    #
    #       ┌──> completed
    #       │
    #   pending ──> running ──┤
    #       │                 │
    #       │                 ├──> failed
    #       │                 │
    #       └──> cancelled    └──> cancelled
    #
    # Three terminal states. Two non-terminal. Once terminal, stays terminal.
    #
    class Step
      STATES = %i[pending running completed failed cancelled].freeze

      attr_reader :id

      def initialize(id: nil, **attributes)
        @id         = id || self.class.generate_id
        @attributes = attributes
        @state      = :pending
        @result     = nil
        @error      = nil
        @task       = nil
        @jobs       = nil
        @mutex      = Mutex.new
      end

      def self.generate_id
        "#{name}-#{Process.pid}-#{Thread.current.object_id}-#{SecureRandom.hex(4)}"
      end

      # Called by the queue's worker. Subclasses override #perform instead.
      def call(task)
        if transition_to_running(task)
          begin
            result = perform(task)
            @mutex.synchronize do
              @result = result
              @state  = :completed
              @task   = nil
            end

          rescue Async::Cancel
            # Cascade to sub-queue before we lose the reference:
            @jobs&.cancel
            @mutex.synchronize do
              @state = :cancelled
              @task  = nil
            end
            raise

          rescue => error
            # Continue-on-failure: record the error, do NOT re-raise.
            @mutex.synchronize do
              @error = error
              @state = :failed
              @task  = nil
            end
          end
        end
      end

      # Subclasses override this.
      def perform(task)
        raise "#{self.class}#perform not implemented"
      end

      # Lazy accessor — creates the sub-queue parented to our running task.
      # Only valid while the step is running (inside #perform).
      def jobs(type: Brute::Queue::SequentialQueue)
        @mutex.synchronize do
          raise "Step not running; sub-queue has nothing to parent to" unless @task
          @jobs ||= type.new(parent: @task).start
        end
      end

      def state
        @mutex.synchronize { @state }
      end

      def result
        @mutex.synchronize { @result }
      end

      def error
        @mutex.synchronize { @error }
      end

      def status
        @mutex.synchronize do
          { id: @id, state: @state, result: @result, error: @error }
        end
      end

      def cancel
        task = @mutex.synchronize do
          case @state
          when :pending
            @state = :cancelled
            nil
          when :running
            @task
          else
            return false # already finished
          end
        end

        task&.cancel
        true
      end

      private

        def transition_to_running(task)
          @mutex.synchronize do
            return false if @state == :cancelled
            @state = :running
            @task  = task
            true
          end
        end
    end
  end
end

test do
  class HelloStep < Brute::Loop::Step
    def perform(task)
      "hello"
    end
  end

  class FailStep < Brute::Loop::Step
    def perform(task)
      raise "boom"
    end
  end

  class SlowStep < Brute::Loop::Step
    def perform(task)
      sleep 10
      "done"
    end
  end

  it "handles IDs" do
    HelloStep.new.id.should.be.kind_of String
    HelloStep.new(id: "custom-1").id.should == "custom-1"
  end

  it "handles initial state" do
    HelloStep.new.state.should == :pending
    HelloStep.new.result.should.be.nil
    HelloStep.new.error.should.be.nil
  end

  it "handles success state" do
    Sync do
      HelloStep.new.tap do |step|
        step.call(Async::Task.current)
        step.state.should == :completed
        step.result.should == "hello"
        step.cancel.should.be.false
      end
    end
  end

  it "handles failed state" do
    Sync do
      FailStep.new.tap do |step|
        lambda { step.call(Async::Task.current) }.should.not.raise
        step.state.should == :failed
        step.error.message.should == "boom"
        step.cancel.should.be.false
      end
    end
  end

  it "handles cancellation" do
    Sync do
      HelloStep.new.tap do |step|
        step.cancel.should.be.true
        step.state.should == :cancelled
        step.call(Async::Task.current)
        step.result.should.be.nil
      end
    end
  end

  # -- status --

  it "status includes id" do
    HelloStep.new(id: "s1").tap do |step|
      step.status[:id].should == "s1"
    end
  end

  it "status includes state" do
    HelloStep.new.tap do |step|
      step.status[:state].should == :pending
    end
  end

  # -- perform not implemented --

  it "raises NotImplementedError for base Step" do
    Sync do
      Brute::Loop::Step.new.tap do |step|
        step.call(Async::Task.current)
        step.state.should == :failed
      end
    end
  end

  # -- jobs raises when not running --

  it "raises when accessing jobs outside perform" do
    lambda { HelloStep.new.jobs(type: Array) }.should.raise(RuntimeError)
  end

  # -- attributes stored --

  it "stores attributes" do
    HelloStep.new(url: "https://example.com").tap do |step|
      step.instance_variable_get(:@attributes)[:url].should == "https://example.com"
    end
  end

  # -- nested sub-queue --

  describe "nesting" do
    class ParentStep < Brute::Loop::Step
      def perform(task)
        3.times { |i| jobs(type: Brute::Queue::SequentialQueue) << HelloStep.new(id: "child-#{i}") }
        jobs.drain
        jobs.steps.map(&:result)
      end
    end

    it "creates a sub-queue inside perform" do
      Sync do
        ParentStep.new.tap do |step|
          step.call(Async::Task.current)
          step.result.should == ["hello", "hello", "hello"]
        end
      end
    end

    it "sub-steps all complete" do
      Sync do
        ParentStep.new.tap do |step|
          step.call(Async::Task.current)
          step.instance_variable_get(:@jobs).steps.all? { |s| s.state == :completed }.should.be.true
        end
      end
    end
  end
end
