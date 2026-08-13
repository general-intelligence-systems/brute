# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Re-invokes the inner stack as long as a condition holds — a generic loop
    # over a turn. The condition is a proc or block that receives env and
    # returns truthy to send control back down the chain again, falsy to stop.
    #
    # The inner app always runs at least once; the condition is checked after
    # each pass (do-while).
    #
    #   # loop while the last message is a tool result (see Loop::ToolResult):
    #   use Brute::Middleware::Loop, ->(env) { env[:messages].last&.role == :tool }
    #
    #   # block form — e.g. bump an iteration counter and stop on should_exit:
    #   use Brute::Middleware::Loop do |env|
    #     env[:current_iteration] += 1
    #     !env[:should_exit] && env[:messages].last&.role == :tool
    #   end
    #
    class Loop
      def initialize(app, condition = nil, &block)
        @app       = app
        @condition = condition || block

        unless @condition.respond_to?(:call)
          raise ArgumentError, "Brute::Middleware::Loop requires a proc or block condition"
        end
      end

      def call(env)
        loop do
          @app.call(env)

          unless @condition.call(env)
            break
          end
        end

        env
      end

      # Loops while the LLM keeps producing tool results — the standard agentic
      # turn loop. After the inner stack runs (the LLM-call proc responds,
      # ToolPipeline executes tools and appends :tool messages), it loops when
      # the last message is a tool result, bumping the iteration counter. It
      # stops when the LLM answers with text only or env[:should_exit] is set
      # (e.g. by MaxIterations).
      #
      #   use Brute::Middleware::Loop::ToolResult
      #
      class ToolResult < Loop
        CONDITION = lambda do |env|
          if env[:should_exit]
            next false
          end

          unless env[:messages].last&.role == :tool
            next false
          end

          env[:current_iteration] += 1

          true
        end

        def initialize(app)
          super(app, CONDITION)
        end
      end
    end
  end
end

__END__

describe "brute/middleware/006_loop" do
  require "brute/messages"

  it "runs the inner app once when the condition is immediately false" do
    calls = 0
    mw = Brute::Middleware::Loop.new(->(_env) { calls += 1 }, ->(_env) { false })
    mw.call({})
    calls.should == 1
  end

  it "loops while the condition is truthy" do
    calls = 0
    mw = Brute::Middleware::Loop.new(->(_env) { calls += 1 }, ->(_env) { calls < 3 })
    mw.call({})
    calls.should == 3
  end

  it "accepts a block condition and passes env to it" do
    seen = []
    mw = Brute::Middleware::Loop.new(->(env) { env[:n] += 1 }) { |env| seen << env[:n]; env[:n] < 2 }
    env = { n: 0 }
    mw.call(env)
    env[:n].should == 2
    seen.should == [1, 2]
  end

  it "returns env" do
    env = { a: 1 }
    Brute::Middleware::Loop.new(->(_e) {}, ->(_e) { false }).call(env).should == env
  end

  it "raises without a proc or block" do
    lambda { Brute::Middleware::Loop.new(->(_e) {}) }.should.raise(ArgumentError)
  end

  # --- Loop::ToolResult (reimplements the old ToolResultLoop) ---

  it "ToolResult loops until the last message is not a tool result" do
    call_count = 0
    inner = ->(env) do
      call_count += 1
      if call_count == 1
        env[:messages] << Brute::Message.new(role: :tool, content: "result", tool_call_id: "tc1")
      else
        env[:messages] << Brute::Message.new(role: :assistant, content: "done")
      end
    end

    mw = Brute::Middleware::Loop::ToolResult.new(inner)
    env = { messages: Brute.log, current_iteration: 1 }
    env[:messages].user("hi")
    mw.call(env)

    call_count.should == 2
    env[:current_iteration].should == 2
    env[:messages].last.role.should == :assistant
  end

  it "ToolResult stops when should_exit is set" do
    call_count = 0
    inner = ->(env) do
      call_count += 1
      env[:messages] << Brute::Message.new(role: :tool, content: "result", tool_call_id: "tc#{call_count}")
      env[:should_exit] = { reason: "max" } if call_count >= 2
    end

    mw = Brute::Middleware::Loop::ToolResult.new(inner)
    env = { messages: Brute.log, current_iteration: 1 }
    env[:messages].user("hi")
    mw.call(env)

    call_count.should == 2
  end

  it "ToolResult does not loop when last message is assistant" do
    call_count = 0
    inner = ->(env) do
      call_count += 1
      env[:messages] << Brute::Message.new(role: :assistant, content: "hello")
    end

    mw = Brute::Middleware::Loop::ToolResult.new(inner)
    env = { messages: Brute.log, current_iteration: 1 }
    env[:messages].user("hi")
    mw.call(env)

    call_count.should == 1
    env[:current_iteration].should == 1
  end
end
