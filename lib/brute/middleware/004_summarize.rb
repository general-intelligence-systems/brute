# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Runs a final tool-free LLM call after the ToolResultLoop completes,
    # ensuring the agent produces a clean summary response.
    #
    # This middleware sits above ToolResultLoop in the stack. After the tool
    # loop finishes (either naturally or via MaxIterations), Summarize
    # injects a summary prompt and calls the inner stack one more time
    # with tools removed. The LLM responds with text only, giving the
    # agent a proper final answer.
    #
    # Stack order:
    #
    #   use Summarize
    #   use ToolResultLoop
    #   use MaxIterations
    #   use ToolCall
    #   run LLMCall.new
    #
    class Summarize
      DEFAULT_PROMPT = "Provide your complete findings based on everything you've explored."

      def initialize(app, prompt: DEFAULT_PROMPT)
        @app = app
        @prompt = prompt
      end

      def call(env)
        @app.call(env)

        saved_tools = env[:tools]
        env[:tools] = []
        env[:current_iteration] = 1
        env[:messages] << RubyLLM::Message.new(role: :user, content: @prompt)
        @app.call(env)
        env[:tools] = saved_tools

        env
      end
    end
  end
end

test do
  require "brute/session"

  it "produces a final assistant message after tool loop" do
    call_count = 0

    # Fake inner app: first call simulates a tool loop ending with a tool message,
    # second call (summary) produces an assistant message.
    inner = ->(env) do
      call_count += 1
      if call_count == 1
        env[:messages] << RubyLLM::Message.new(role: :tool, content: "some result", tool_call_id: "tc1")
      else
        env[:messages] << RubyLLM::Message.new(role: :assistant, content: "Here is my complete summary.")
      end
    end

    mw = Brute::Middleware::Summarize.new(inner)
    session = Brute::Session.new
    session.user("explore the codebase")
    env = { messages: session, tools: [:some_tool], current_iteration: 5 }
    mw.call(env)

    env[:messages].last.role.should == :assistant
    env[:messages].last.content.should =~ /summary/i
  end

  it "restores tools after summary call" do
    inner = ->(env) {
      env[:messages] << RubyLLM::Message.new(role: :assistant, content: "done")
    }

    mw = Brute::Middleware::Summarize.new(inner)
    tools = [:read, :search]
    env = { messages: Brute::Session.new, tools: tools.dup, current_iteration: 1 }
    env[:messages].user("hi")
    mw.call(env)

    env[:tools].should == tools
  end

  it "resets current_iteration for the summary call" do
    captured_iteration = nil
    inner = ->(env) {
      captured_iteration = env[:current_iteration]
      env[:messages] << RubyLLM::Message.new(role: :assistant, content: "done")
    }

    mw = Brute::Middleware::Summarize.new(inner)
    env = { messages: Brute::Session.new, tools: [], current_iteration: 99 }
    env[:messages].user("hi")
    mw.call(env)

    # The second call (summary) should have iteration reset to 1
    captured_iteration.should == 1
  end

  it "injects a summary prompt message" do
    messages_at_second_call = nil
    call_count = 0
    inner = ->(env) {
      call_count += 1
      messages_at_second_call = env[:messages].map(&:content) if call_count == 2
      env[:messages] << RubyLLM::Message.new(role: :assistant, content: "done")
    }

    mw = Brute::Middleware::Summarize.new(inner)
    env = { messages: Brute::Session.new, tools: [], current_iteration: 1 }
    env[:messages].user("hi")
    mw.call(env)

    messages_at_second_call.last.should =~ /findings/i
  end

  it "accepts a custom prompt" do
    messages_at_second_call = nil
    call_count = 0
    inner = ->(env) {
      call_count += 1
      messages_at_second_call = env[:messages].map(&:content) if call_count == 2
      env[:messages] << RubyLLM::Message.new(role: :assistant, content: "done")
    }

    mw = Brute::Middleware::Summarize.new(inner, prompt: "Give me the TL;DR.")
    env = { messages: Brute::Session.new, tools: [], current_iteration: 1 }
    env[:messages].user("hi")
    mw.call(env)

    messages_at_second_call.last.should == "Give me the TL;DR."
  end
end
