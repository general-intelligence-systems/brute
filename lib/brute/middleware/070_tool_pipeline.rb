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

                # Lifecycle hooks (Brute::Hooks): before_tool may rewrite
                # :arguments or short-circuit with a :result; approve_tool
                # denies on a false (or String) return; after_tool may
                # rewrite :result.
                call_env = {
                  name:      name.to_s,
                  arguments: args,
                  result:    nil,
                  events:    env[:events],
                  metadata:  {},
                  turn_env:  env,
                }
                if (hooks = env[:hooks])
                  responses = hooks.emit(:before_tool, call_env).compact
                  call_env[:result] = responses.last if call_env[:result].nil? && !responses.empty?

                  if call_env[:result].nil?
                    denial = hooks.emit(:approve_tool, call_env).find { |r| r == false || r.is_a?(String) }
                    unless denial.nil?
                      call_env[:result] = denial.is_a?(String) ? denial : %(Tool call to "#{name}" was denied.)
                    end
                  end
                end

                result = if call_env[:result].nil?
                           available_tools[name].call(call_env[:arguments])
                         else
                           call_env[:result]
                         end

                if (hooks = env[:hooks])
                  call_env[:result] = result
                  hooks.emit(:after_tool, call_env)
                  result = call_env[:result]
                end

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

  # --- lifecycle hooks (Brute::Hooks) ---

  def hook_env(hooks)
    { messages: Brute.log, events: [], hooks: hooks }
  end

  it "before_tool may rewrite arguments and short-circuit with a result" do
    tool = { name: "echo", description: "", execute: ->(text:) { "ran:#{text}" } }
    inner = ->(env) do
      env[:messages] << Brute::Message.new(role: :assistant, content: "",
        tool_calls: [{ id: "tc1", name: "echo", arguments: { "text" => "orig" } }])
    end
    hooks = Brute::Hooks.new
    hooks.on(:before_tool) { |call| call[:arguments] = { text: "rewritten" }; nil }
    mw = Brute::Middleware::ToolPipeline.new(inner, tools: [tool])
    env = hook_env(hooks)
    env[:messages].user("hi")
    mw.call(env)
    env[:messages].last.content.should == "ran:rewritten"

    hooks2 = Brute::Hooks.new
    hooks2.on(:before_tool) { |_call| "canned" }
    mw2 = Brute::Middleware::ToolPipeline.new(inner, tools: [tool])
    env2 = hook_env(hooks2)
    env2[:messages].user("hi")
    mw2.call(env2)
    env2[:messages].last.content.should == "canned" # never executed
  end

  it "approve_tool denies on false (generic message) or String (custom)" do
    tool = { name: "exec", description: "", execute: ->(**) { "ran" } }
    inner = ->(env) do
      env[:messages] << Brute::Message.new(role: :assistant, content: "",
        tool_calls: [{ id: "tc1", name: "exec", arguments: {} }])
    end
    hooks = Brute::Hooks.new
    hooks.on(:approve_tool) { |_call| false }
    env = hook_env(hooks)
    env[:messages].user("hi")
    Brute::Middleware::ToolPipeline.new(inner, tools: [tool]).call(env)
    env[:messages].last.content.should == %(Tool call to "exec" was denied.)

    hooks2 = Brute::Hooks.new
    hooks2.on(:approve_tool) { |_call| "denied by policy" }
    env2 = hook_env(hooks2)
    env2[:messages].user("hi")
    Brute::Middleware::ToolPipeline.new(inner, tools: [tool]).call(env2)
    env2[:messages].last.content.should == "denied by policy"
  end

  it "after_tool may rewrite the result" do
    tool = { name: "echo", description: "", execute: ->(**) { "raw" } }
    inner = ->(env) do
      env[:messages] << Brute::Message.new(role: :assistant, content: "",
        tool_calls: [{ id: "tc1", name: "echo", arguments: {} }])
    end
    hooks = Brute::Hooks.new
    hooks.on(:after_tool) { |call| call[:result] = "rewrote(#{call[:result]})" }
    env = hook_env(hooks)
    env[:messages].user("hi")
    Brute::Middleware::ToolPipeline.new(inner, tools: [tool]).call(env)
    env[:messages].last.content.should == "rewrote(raw)"
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
