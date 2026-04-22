# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Queue
  # A queue that processes steps concurrently up to a limit.
  # Workers match concurrency slots.
  class ParallelQueue < BaseQueue
    def initialize(concurrency: 4, parent: Async::Task.current)
      super(concurrency: concurrency, worker_count: concurrency, parent: parent)
    end
  end
  end
end

test do
  it "runs steps concurrently" do
    Sync do
      concurrent = 0
      max_concurrent = 0

      steps = 4.times.map do
        Class.new(Brute::Loop::Step) do
          define_method(:perform) do |task|
            concurrent += 1
            max_concurrent = [max_concurrent, concurrent].max
            sleep 0.05
            concurrent -= 1
          end
        end.new
      end

      q = Brute::Queue::ParallelQueue.new(concurrency: 4)
      steps.each { |s| q << s }
      q.start
      q.drain
      (max_concurrent > 1).should.be.true
    end
  end

  it "limits concurrency to the specified amount" do
    Sync do
      concurrent = 0
      max_concurrent = 0

      steps = 8.times.map do
        Class.new(Brute::Loop::Step) do
          define_method(:perform) do |task|
            concurrent += 1
            max_concurrent = [max_concurrent, concurrent].max
            sleep 0.05
            concurrent -= 1
          end
        end.new
      end

      q = Brute::Queue::ParallelQueue.new(concurrency: 2)
      steps.each { |s| q << s }
      q.start
      q.drain
      (max_concurrent <= 2).should.be.true
    end
  end
end
