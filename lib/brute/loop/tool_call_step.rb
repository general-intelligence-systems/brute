# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Loop
  # A Step that wraps an LLM::Function tool call.
  #
  # Identity comes from the function's call ID so tool results
  # can be correlated back to the LLM's request.
  #
  class ToolCallStep < Step
    attr_reader :function

    def initialize(function:, **rest)
      super(id: function.id, **rest)
      @function = function
    end

    def perform(task)
      @function.call
    end
  end
  end
end

test do
  FakeFunction = Struct.new(:id, :name, :arguments, :return_value) do
    def call
      return_value
    end
  end

  class FailFunction
    attr_reader :id, :name, :arguments
    def initialize
      @id = "fail_1"
      @name = "fail"
      @arguments = {}
    end
    def call
      raise "tool exploded"
    end
  end

  it "uses function id as step id" do
    fn = FakeFunction.new("call_123", "read", {}, "content")
    Brute::Loop::ToolCallStep.new(function: fn).id.should == "call_123"
  end

  it "calls the function in perform" do
    Sync do
      fn = FakeFunction.new("call_1", "read", {}, "file contents")
      step = Brute::Loop::ToolCallStep.new(function: fn)
      step.call(Async::Task.current)
      step.result.should == "file contents"
    end
  end

  it "transitions to completed on success" do
    Sync do
      fn = FakeFunction.new("call_2", "write", {}, "ok")
      step = Brute::Loop::ToolCallStep.new(function: fn)
      step.call(Async::Task.current)
      step.state.should == :completed
    end
  end

  it "captures function as accessor" do
    fn = FakeFunction.new("call_3", "shell", {}, nil)
    Brute::Loop::ToolCallStep.new(function: fn).function.should.be.identical_to fn
  end

  it "transitions to failed when function raises" do
    Sync do
      step = Brute::Loop::ToolCallStep.new(function: FailFunction.new)
      step.call(Async::Task.current)
      step.state.should == :failed
    end
  end

  it "captures function error" do
    Sync do
      step = Brute::Loop::ToolCallStep.new(function: FailFunction.new)
      step.call(Async::Task.current)
      step.error.message.should == "tool exploded"
    end
  end
end
