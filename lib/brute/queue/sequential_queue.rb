# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Queue
  # A queue that processes steps one at a time, in order.
  # One worker, one concurrency slot.
  class SequentialQueue < BaseQueue
    def initialize(parent: Async::Task.current)
      super(concurrency: 1, worker_count: 1, parent: parent)
    end
  end
  end
end

test do
  class OrderStep < Brute::Loop::Step
    def perform(task)
      @attributes[:log] << @attributes[:value]
      sleep(@attributes[:delay]) if @attributes[:delay]
      @attributes[:value]
    end
  end

  it "processes steps in order" do
    Sync do
      log = []
      q = Brute::Queue::SequentialQueue.new
      q << OrderStep.new(log: log, value: "a", delay: 0.01)
      q << OrderStep.new(log: log, value: "b", delay: 0.01)
      q << OrderStep.new(log: log, value: "c", delay: 0.01)
      q.start
      q.drain
      log.should == ["a", "b", "c"]
    end
  end

  it "runs only one step at a time" do
    Sync do
      concurrent = 0
      max_concurrent = 0

      steps = 3.times.map do
        Class.new(Brute::Loop::Step) do
          define_method(:perform) do |task|
            concurrent += 1
            max_concurrent = [max_concurrent, concurrent].max
            sleep 0.02
            concurrent -= 1
          end
        end.new
      end

      q = Brute::Queue::SequentialQueue.new
      steps.each { |s| q << s }
      q.start
      q.drain
      max_concurrent.should == 1
    end
  end
end
