# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/truncation"
require "async"
require "async/barrier"

module Brute
  module Middleware
    class ToolPipeline
      def initialize(app, tools: [])
        @app   = app
        @tools = tools
      end

      def call(env)
        env[:tools] = @tools
        @app.call(env)

        response = env[:messages].last

        if response.respond_to?(:tool_calls) && response.tool_calls.present?
          tools_to_run = response.tool_calls

          # tool_to_run may be an Array (Brute::ToolCall) or an id-keyed Hash (some libraries' native shape)
          if tools_to_run.respond_to?(:values)
            tools_to_run = tools_to_run.values
          end

          # No idea why we use Array() here... probably in case it's a hash or something...
          # because reject would work on the hash...
          tools_to_run = Array(tools_to_run).reject { |tc| tc.name == "question" }

          available_tools = Brute::Tools::Adapter.wrap_all(env[:tools])
          env[:events] << on_tool_call_start_event(tools_to_run)

          results = []

          # Async::Barrier blocks until all tasks are complete.
          # Tasks run in parrallel.
          #
          Sync do
            barrier = Async::Barrier.new

            tools_to_run.each do |tool_call|
              barrier.async do 
                name = tool_call.name.to_sym
                args = tool_call.arguments

                available_tools[name].call(args).then do |result|

                  # Coerce to String so Hash results (e.g. Shell's
                  # {stdout:, stderr:, exit_code:}) serialize predictably.
                  if result.is_a?(String)
                    content = result
                  else
                    content = result.to_s
                  end

                  # Universal truncation safety net — skip if already truncated
                  unless Brute::Truncation.already_truncated?(content)
                    content = Brute::Truncation.truncate(content)
                  end

                  results << [tool_call, content]
                end
              rescue => e
                # Capture the error as a tool result so the LLM can see it
                # and reason about the failure, rather than crashing the
                # entire middleware chain.
                env[:events] << { type: :error, data: { error: e, message: e.message } }
                results << [tool_call, "Error: #{e.class}: #{e.message}"]
              end
            end

            barrier.wait
          ensure
            barrier&.cancel
          end

          # Append events and messages in the original tool_call order so the
          # LLM sees a deterministic sequence regardless of completion order.
          results.sort_by! { |tool_call, _| tools_to_run.index(tool_call) }

          results.each do |tool_call, content|
            env[:events] << { type: :tool_result, data: { name: tool_call.name, content: content } }
            env[:messages] << Brute::Message.new(role: :tool, content: content, tool_call_id: tool_call.id)
          end
        end

        env
      end

      private

        def on_tool_call_start_event(pending_tools)
          {
            type: :tool_call_start,
            data: pending_tools.map { |tc|
              {
                name: tc.name,
                call_id: tc.id,
                arguments: tc.arguments
              }
            }
          }
        end
    end
  end
end

__END__

describe "brute/middleware/070_tool_pipeline" do
  require "brute/messages"
  require "brute/truncation"

  it "passes through when no tool calls pending" do
    inner = ->(env) {
      env[:messages] << Brute::Message.new(role: :assistant, content: "hi")
    }
    mw = Brute::Middleware::ToolPipeline.new(inner, tools: [])
    env = {
      messages: Brute.log,
      events: [],
    }
    env[:messages].user("hello")
    mw.call(env)
    env[:messages].last.content.should == "hi"
  end

  it "advertises its tools on env[:tools] on the way in" do
    seen = nil
    inner = ->(env) { seen = env[:tools] }
    tool = { name: "echo", description: "", execute: ->(**) { "ok" } }
    mw = Brute::Middleware::ToolPipeline.new(inner, tools: [tool])
    env = { messages: Brute.log, events: [] }
    env[:messages].user("hi")
    mw.call(env)
    seen.should == [tool]
  end

  # --- Universal output truncation ---

  it "truncates large tool results via Truncation" do
    # A fake tool that returns a huge string
    big_tool = Class.new(Brute::Tool) do
      description "test tool"
      param :input, type: "string", desc: "input"
      def name; "big_tool"; end
      def execute(input:)
        "line\n" * 3000
      end
    end

    tool_calls = [
      Brute::ToolCall.new(
        id: "tc_1",
        name: "big_tool",
        arguments: { "input" => "go" },
      )
    ]

    inner = ->(env) {
      env[:messages] << Brute::Message.new(role: :assistant, content: "", tool_calls: tool_calls)
    }
    mw = Brute::Middleware::ToolPipeline.new(inner, tools: [big_tool])
    env = {
      messages: Brute.log,
      events: [],
    }
    env[:messages].user("hello")
    mw.call(env)

    tool_msg = env[:messages].select { |m| m.role == :tool }.last
    tool_msg.content.lines.size.should.be < 2100
    tool_msg.content.should =~ /truncated/i
  end

  # --- Skip double-truncation ---

  it "does not double-truncate already-truncated output" do
    # A fake tool that returns output already containing the truncation marker
    pre_truncated_tool = Class.new(Brute::Tool) do
      description "test tool"
      param :input, type: "string", desc: "input"
      def name; "pre_truncated_tool"; end
      def execute(input:)
        "some result\n[Output truncated: showing 100 of 5000 lines]"
      end
    end

    tool_calls = [
      Brute::ToolCall.new(
        id: "tc_2",
        name: "pre_truncated_tool",
        arguments: { "input" => "go" },
      )
    ]

    inner = ->(env) {
      env[:messages] << Brute::Message.new(role: :assistant, content: "", tool_calls: tool_calls)
    }
    mw = Brute::Middleware::ToolPipeline.new(inner, tools: [pre_truncated_tool])
    env = {
      messages: Brute.log,
      events: [],
    }
    env[:messages].user("hello")
    mw.call(env)

    tool_msg = env[:messages].select { |m| m.role == :tool }.last
    # Should contain exactly one truncation marker, not two
    tool_msg.content.scan(/Output truncated/).size.should == 1
  end
end
