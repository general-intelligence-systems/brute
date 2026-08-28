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
    class Loop < Brute::Middleware::Base
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
      # It also loops on a completion that only thought: a reasoning model
      # sometimes returns its thinking and stops — no text, no tool call —
      # having decided what to do without doing it. That is not an answer, and
      # the turn is not over; the thinking goes back with the conversation,
      # which is what the provider asks for anyway, and the model does what it
      # had already worked out.
      #
      #   use Brute::Middleware::Loop::ToolResult
      #
      class ToolResult < Loop
        CONDITION = lambda do |env|
          if env[:should_exit]
            next false
          end

          unless env[:messages].last&.role == :tool || ToolResult.thought_only?(env[:messages].last)
            next false
          end

          env[:current_iteration] += 1

          true
        end

        # Thinking, and nothing done with it.
        def self.thought_only?(message)
          message&.role == :assistant &&
            message.reasoning &&
            message.content.to_s.strip.empty? &&
            !message.tool_call?
        end

        def initialize(app)
          super(app, CONDITION)
        end
      end

      # Keeps the turn alive while background jobs are running. Sit it
      # OUTSIDE the tool loop: the inner loop ends when the model answers
      # with text, and this one sends control back in for another pass while
      # jobs are still running — which is how a finished job gets reported.
      # Whatever spawns the jobs (say, a middleware running a subagent in
      # the background) keeps env[:background_jobs] current.
      #
      #   use Brute::Middleware::Loop::BackgroundJobs
      #   use Brute::Middleware::Loop::ToolResult
      #
      class BackgroundJobs < Loop
        CONDITION = ->(env) { env[:background_jobs] }

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

  it "runs the app until the condition turns false, passing it env" do
    passes = []
    env = { n: 0 }
    returned = Brute::Middleware::Loop.new(->(e) { e[:n] += 1; passes << e[:n]; e }) { |e| e[:n] < 3 }.call(env)

    passes.should == [1, 2, 3]
    returned.should.be.identical_to env

    lambda { Brute::Middleware::Loop.new(->(_e) {}) }.should.raise(ArgumentError)
  end

  # --- Loop::ToolResult (reimplements the old ToolResultLoop) ---

  it "ToolResult reruns while the last message is a tool result, unless should_exit" do
    calls = []
    inner = ->(env) do
      calls << env[:current_iteration]
      env[:messages] << Brute::Message.new(role: :tool, content: "result", tool_call_id: "tc#{calls.size}")
      env[:should_exit] = { reason: "max" } if calls.size >= 2
    end

    env = { messages: Brute.log.tap { |l| l.user("hi") }, current_iteration: 1 }
    Brute::Middleware::Loop::ToolResult.new(inner).call(env)
    calls.should == [1, 2]

    calls.clear
    text_only = ->(env) do
      calls << env[:current_iteration]
      env[:messages] << Brute::Message.new(role: :assistant, content: "done")
    end
    env = { messages: Brute.log.tap { |l| l.user("hi") }, current_iteration: 1 }
    Brute::Middleware::Loop::ToolResult.new(text_only).call(env)
    calls.should == [1]
    env[:current_iteration].should == 1
  end

  # --- Loop::BackgroundJobs ---

  it "ToolResult reruns on a completion that only thought, so the turn is not lost" do
    # A reasoning model sometimes returns the thinking and stops, having
    # decided what to do without doing it. The turn is not over: the thinking
    # goes back and the model does what it had worked out.
    thought = Brute::Message.new(role: :assistant, reasoning: "I should list the events")

    env = { messages: Brute.log.tap { |log| log << thought }, current_iteration: 1 }
    Brute::Middleware::Loop::ToolResult::CONDITION.call(env).should.be.true
    env[:current_iteration].should == 2

    # An answer, or a tool call it did make, ends the turn as before.
    answered = { messages: Brute.log.tap { |log| log.assistant("here they are") }, current_iteration: 1 }
    Brute::Middleware::Loop::ToolResult::CONDITION.call(answered).should.be.false

    calling = Brute::Message.new(role: :assistant, reasoning: "I should list them",
      tool_calls: [{ id: "tc1", name: "list_events", arguments: {} }])
    called = { messages: Brute.log.tap { |log| log << calling }, current_iteration: 1 }
    Brute::Middleware::Loop::ToolResult::CONDITION.call(called).should.be.false
  end

  it "BackgroundJobs reruns while jobs are running" do
    seen = []
    inner = ->(env) { seen << env[:background_jobs]; env[:background_jobs] = seen.size < 3 }

    Brute::Middleware::Loop::BackgroundJobs.new(inner).call({})
    seen.should == [nil, true, true]

    seen.clear
    Brute::Middleware::Loop::BackgroundJobs.new(->(e) { seen << e[:background_jobs]; e[:background_jobs] = false })
      .call({ background_jobs: true })
    seen.should == [true]
  end
end
