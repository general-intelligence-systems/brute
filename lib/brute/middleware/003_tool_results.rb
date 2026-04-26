# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Re-invokes the inner stack whenever the last message is a :tool result.
    #
    # After the inner pipeline runs (LLMCall responds, ToolCall executes tools
    # and appends :tool messages), this middleware checks if tool results are
    # pending. If so, it increments the iteration counter and loops — sending
    # the tool results back through MaxIterations → ToolCall → LLMCall so the
    # LLM can see them.
    #
    # The loop breaks when:
    #   - The LLM responds with text only (no tool calls) — last message is :assistant
    #   - env[:should_exit] is set (e.g. by MaxIterations)
    #
    class ToolResults
      def initialize(app)
        @app = app
      end

      def call(env)
        loop do
          @app.call(env)

          brea if env[:should_exit]
          break unless env[:messages].last&.role == :tool

          env[:current_iteration] += 1
        end

        env
      end
    end
  end
end

test do
  require "brute/session"

  it "loops until last message is not a tool result" do
    call_count = 0

    # Fake inner app: first call appends a :tool message, second call appends :assistant
    inner = ->(env) do
      call_count += 1
      if call_count == 1
        env[:messages] << RubyLLM::Message.new(role: :tool, content: "result", tool_call_id: "tc1")
      else
        env[:messages] << RubyLLM::Message.new(role: :assistant, content: "done")
      end
    end

    mw = Brute::Middleware::ToolResults.new(inner)
    env = { messages: Brute::Session.new, current_iteration: 1 }
    env[:messages].user("hi")

    mw.call(env)

    call_count.should == 2
    env[:current_iteration].should == 2
    env[:messages].last.role.should == :assistant
  end

  it "stops when should_exit is set" do
    call_count = 0

    inner = ->(env) do
      call_count += 1
      env[:messages] << RubyLLM::Message.new(role: :tool, content: "result", tool_call_id: "tc#{call_count}")
      env[:should_exit] = { reason: "max" } if call_count >= 2
    end

    mw = Brute::Middleware::ToolResults.new(inner)
    env = { messages: Brute::Session.new, current_iteration: 1 }
    env[:messages].user("hi")

    mw.call(env)

    call_count.should == 2
  end

  it "does not loop when last message is assistant" do
    call_count = 0

    inner = ->(env) do
      call_count += 1
      env[:messages] << RubyLLM::Message.new(role: :assistant, content: "hello")
    end

    mw = Brute::Middleware::ToolResults.new(inner)
    env = { messages: Brute::Session.new, current_iteration: 1 }
    env[:messages].user("hi")

    mw.call(env)

    call_count.should == 1
    env[:current_iteration].should == 1
  end
end
