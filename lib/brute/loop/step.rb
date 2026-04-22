# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

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
      return unless transition_to_running(task)

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

  # -- identity --

  it "generates a unique id" do
    HelloStep.new.id.should.be.kind_of String
  end

  it "accepts a custom id" do
    HelloStep.new(id: "custom-1").id.should == "custom-1"
  end

  # -- initial state --

  it "starts in pending state" do
    HelloStep.new.state.should == :pending
  end

  it "starts with nil result" do
    HelloStep.new.result.should.be.nil
  end

  it "starts with nil error" do
    HelloStep.new.error.should.be.nil
  end

  # -- successful execution --

  it "transitions to completed on success" do
    Sync do
      step = HelloStep.new
      step.call(Async::Task.current)
      step.state.should == :completed
    end
  end

  it "captures the return value as result" do
    Sync do
      step = HelloStep.new
      step.call(Async::Task.current)
      step.result.should == "hello"
    end
  end

  # -- failed execution --

  it "transitions to failed on error" do
    Sync do
      step = FailStep.new
      step.call(Async::Task.current)
      step.state.should == :failed
    end
  end

  it "captures the exception as error" do
    Sync do
      step = FailStep.new
      step.call(Async::Task.current)
      step.error.message.should == "boom"
    end
  end

  it "does not re-raise on failure" do
    Sync do
      step = FailStep.new
      lambda { step.call(Async::Task.current) }.should.not.raise
    end
  end

  # -- cancellation of pending step --

  it "cancel returns true for pending step" do
    HelloStep.new.cancel.should.be.true
  end

  it "transitions pending step to cancelled" do
    step = HelloStep.new
    step.cancel
    step.state.should == :cancelled
  end

  it "skips perform when cancelled before call" do
    Sync do
      step = HelloStep.new
      step.cancel
      step.call(Async::Task.current)
      step.result.should.be.nil
    end
  end

  # -- cancellation of finished step --

  it "cancel returns false for completed step" do
    Sync do
      step = HelloStep.new
      step.call(Async::Task.current)
      step.cancel.should.be.false
    end
  end

  it "cancel returns false for failed step" do
    Sync do
      step = FailStep.new
      step.call(Async::Task.current)
      step.cancel.should.be.false
    end
  end

  # -- status --

  it "status includes id" do
    step = HelloStep.new(id: "s1")
    step.status[:id].should == "s1"
  end

  it "status includes state" do
    step = HelloStep.new
    step.status[:state].should == :pending
  end

  # -- perform not implemented --

  it "raises NotImplementedError for base Step" do
    Sync do
      step = Brute::Loop::Step.new
      step.call(Async::Task.current)
      step.state.should == :failed
    end
  end

  # -- jobs raises when not running --

  it "raises when accessing jobs outside perform" do
    lambda { HelloStep.new.jobs(type: Array) }.should.raise(RuntimeError)
  end

  # -- attributes stored --

  it "stores attributes" do
    step = HelloStep.new(url: "https://example.com")
    step.instance_variable_get(:@attributes)[:url].should == "https://example.com"
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
        step = ParentStep.new
        step.call(Async::Task.current)
        step.result.should == ["hello", "hello", "hello"]
      end
    end

    it "sub-steps all complete" do
      Sync do
        step = ParentStep.new
        step.call(Async::Task.current)
        step.instance_variable_get(:@jobs).steps.all? { |s| s.state == :completed }.should.be.true
      end
    end
  end
end
