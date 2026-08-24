# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Runs a final tool-free LLM call after the Loop::ToolResult completes,
    # ensuring the agent produces a clean summary response.
    #
    # This middleware sits above Loop::ToolResult in the stack. After the tool
    # loop finishes (either naturally or via MaxIterations), Summarize
    # injects a summary prompt and calls the inner stack one more time
    # with tools removed. The LLM responds with text only, giving the
    # agent a proper final answer.
    #
    # Stack order:
    #
    #   use Summarize
    #   use Loop::ToolResult
    #   use MaxIterations
    #   use ToolPipeline
    #   run ->(env) { ... }   # inline LLM call proc (see Brute.agent)
    #
    class Summarize < Brute::Middleware::Base
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
        env[:messages] << Brute::Message.new(role: :user, content: @prompt)
        @app.call(env)
        env[:tools] = saved_tools

        env
      end
    end
  end
end

__END__

describe "brute/middleware/004_summarize" do
  require "brute/messages"

  it "reruns the stack tool-free with a summary prompt, then restores the tools" do
    seen = []
    inner = ->(env) do
      seen << [env[:tools], env[:current_iteration], env[:messages].last.content]
      env[:messages] << Brute::Message.new(role: :assistant, content: "done")
    end

    env = { messages: Brute.log.tap { |l| l.user("explore the codebase") },
            tools: [:read, :search], current_iteration: 5 }
    Brute::Middleware::Summarize.new(inner).call(env)

    seen.should == [
      [[:read, :search], 5, "explore the codebase"],
      [[], 1, Brute::Middleware::Summarize::DEFAULT_PROMPT],
    ]
    env[:tools].should == [:read, :search]

    seen.clear
    Brute::Middleware::Summarize.new(inner, prompt: "Give me the TL;DR.").call(env)
    seen.last.last.should == "Give me the TL;DR."
  end
end
