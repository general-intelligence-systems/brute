# frozen_string_literal: true

require "bundler/setup"
require "brute"

require "async"
require "async/queue"
require "async/barrier"
require "async/semaphore"

module Brute
  module Queue
    # A queue that dequeues Step objects and runs them, honoring cancellation.
    #
    # Composes four async primitives:
    #   - An inbox (Async::Queue) that holds pending steps
    #   - A barrier (Async::Barrier) that tracks every task the queue spawns
    #   - A semaphore (Async::Semaphore) parented to the barrier, limiting concurrency
    #   - Workers — long-lived tasks that dequeue from the inbox and run steps
    #
    # The barrier-semaphore composition via parent: means every task the
    # semaphore spawns is also tracked by the barrier. One call site
    # (semaphore.async), two guarantees (scoped lifetime + bounded concurrency).
    #
    class BaseQueue
      attr_reader :steps

      def initialize(concurrency:, worker_count:, parent: Async::Task.current)
        @steps        = []
        @inbox        = Async::Queue.new
        @barrier      = Async::Barrier.new(parent: parent)
        @semaphore    = Async::Semaphore.new(concurrency, parent: @barrier)
        @worker_count = worker_count
        @started      = false
      end

      def <<(step)
        @steps << step
        @inbox.push(step)
        self
      end

      def first = @steps.first
      def last  = @steps.last

      def start
        return self if @started
        @started = true

        @worker_count.times do
          @barrier.async do
            while (step = @inbox.dequeue)
              @semaphore.async do |task|
                step.call(task)
              end
            end
          end
        end
        self
      end

      # Graceful: stop accepting, wait for running work to finish.
      def drain
        @inbox.close
        @barrier.wait
      end

      # Hard: close inbox, cancel pending steps, cancel running work.
      def cancel
        @inbox.close
        @steps.each do |step|
          step.cancel if step.state == :pending
        end
        @barrier.cancel
      end
    end
  end
end

test do
  class CountStep < Brute::Loop::Step
    def perform(task)
      @attributes[:counter] << @attributes[:value]
      @attributes[:value]
    end
  end

  class SleepStep < Brute::Loop::Step
    def perform(task)
      sleep(@attributes[:duration])
      "slept"
    end
  end

  # -- enqueue --

  it "appends steps to the steps list" do
    Sync do
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      q << CountStep.new(counter: [], value: 1)
      q.steps.size.should == 1
    end
  end

  it "returns self from <<" do
    Sync do
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      (q << CountStep.new(counter: [], value: 1)).should.be.identical_to q
    end
  end

  # -- first / last --

  it "returns the first step" do
    Sync do
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      s1 = CountStep.new(counter: [], value: 1)
      s2 = CountStep.new(counter: [], value: 2)
      q << s1 << s2
      q.first.should.be.identical_to s1
    end
  end

  it "returns the last step" do
    Sync do
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      s1 = CountStep.new(counter: [], value: 1)
      s2 = CountStep.new(counter: [], value: 2)
      q << s1 << s2
      q.last.should.be.identical_to s2
    end
  end

  # -- start + drain --

  it "runs steps to completion on drain" do
    Sync do
      results = []
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      q << CountStep.new(counter: results, value: "a")
      q << CountStep.new(counter: results, value: "b")
      q.start
      q.drain
      results.should == ["a", "b"]
    end
  end

  it "completes all steps" do
    Sync do
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      q << CountStep.new(counter: [], value: 1)
      q << CountStep.new(counter: [], value: 2)
      q.start
      q.drain
      q.steps.all? { |s| s.state == :completed }.should.be.true
    end
  end

  it "captures results on each step" do
    Sync do
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      q << CountStep.new(counter: [], value: 42)
      q.start
      q.drain
      q.first.result.should == 42
    end
  end

  it "is idempotent on start" do
    Sync do
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      q << CountStep.new(counter: [], value: 1)
      q.start
      q.start # should not double-spawn workers
      q.drain
      q.steps.size.should == 1
    end
  end

  # -- cancel --

  it "marks pending steps as cancelled" do
    Sync do
      q = Brute::Queue::BaseQueue.new(concurrency: 1, worker_count: 1)
      s1 = SleepStep.new(duration: 10)
      s2 = SleepStep.new(duration: 10)
      s3 = SleepStep.new(duration: 10)
      q << s1 << s2 << s3
      q.start
      sleep 0.01 # let worker pick up s1
      q.cancel
      # s2 and s3 should be cancelled (they were pending)
      [s2, s3].all? { |s| s.state == :cancelled }.should.be.true
    end
  end

  # -- concurrent execution --

  it "runs multiple steps concurrently" do
    Sync do
      started = []
      done = []

      steps = 3.times.map do |i|
        Class.new(Brute::Loop::Step) do
          define_method(:perform) do |task|
            started << i
            sleep 0.05
            done << i
            i
          end
        end.new
      end

      q = Brute::Queue::BaseQueue.new(concurrency: 3, worker_count: 3)
      steps.each { |s| q << s }
      q.start
      q.drain
      done.size.should == 3
    end
  end
end
