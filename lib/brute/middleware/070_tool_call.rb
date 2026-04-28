# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/truncation"
require "async"
require "async/barrier"

module Brute
  module Middleware
    # Executes pending tool calls from the LLM response.
    #
    # Existing features (ref: opencode tool.ts wrap / truncate.ts):
    #
    # 1. Universal output truncation — after every tool.call(), pass the
    #    result string through Brute::Truncation.truncate() which enforces
    #    a 2000-line / 50 KB cap. This is a safety net so no single tool
    #    result can blow up the context window, regardless of whether the
    #    tool itself has internal limits.
    # 2. Overflow to disk — when truncating, the full output is saved to
    #    a temp file under the truncation directory. The path is included
    #    in the truncated result with a hint.
    # 3. Configurable limits — MAX_LINES / MAX_BYTES default to 2000 / 50 KB.
    # 4. Skip truncation when tool already truncated — if the tool result
    #    already contains the truncation marker (e.g. Shell or FSSearch
    #    truncated internally), don't double-truncate.
    #
    # == Concurrency model (Async)
    #
    # Tool calls are executed concurrently using the `async` gem's fiber-based
    # scheduler. Each tool call is dispatched as an Async::Task inside an
    # Async::Barrier, so all tools run in parallel and we wait for every task
    # to complete before moving on.
    #
    # Key design decisions:
    #
    # - Sync {} (not Async{}.wait) — reuses an existing event loop if one is
    #   already running, or creates one on demand. Blocks the caller until all
    #   inner work completes, which is what the middleware stack requires.
    #
    # - Async::Barrier — the idiomatic fan-out / join primitive. Each tool call
    #   becomes a child task via barrier.async; barrier.wait blocks until every
    #   task finishes. This is preferable to Async::Queue for a fixed batch of
    #   work with no producer/consumer relationship.
    #
    # - Deterministic result ordering — tool results are collected into an array
    #   during concurrent execution, then sorted back into the original
    #   tools_to_run key order before appending to env[:messages]. This ensures
    #   the LLM always sees results in a stable order regardless of which tool
    #   finishes first.
    #
    # - Fiber-safe shared state — appending to the results array from multiple
    #   fibers is safe because Async fibers are cooperatively scheduled (only
    #   one fiber runs at a time within a Sync block). No mutex needed.
    #
    # - FileMutationQueue compatibility — tools that mutate files use
    #   Brute::Queue::FileMutationQueue.serialize, which uses Ruby 3.4's
    #   fiber-scheduler-aware Mutex. Operations on the same file are serialized;
    #   operations on different files proceed in parallel.
    #
    class ToolCall
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)

        tools_to_run = pending_tool_calls(env[:messages].last)
        if tools_to_run.any?
          available_tools = resolve_tools(env[:tools])
          env[:events] << on_tool_call_start_event(tools_to_run)

          results = []

          Sync do
            barrier = Async::Barrier.new

            tools_to_run.each do |id, tool_call|
              barrier.async do
                tool = available_tools[tool_call.name.to_sym]
                result = tool.call(tool_call.arguments)

                # Coerce to String so RubyLLM::Message doesn't treat Hash results
                # (e.g. Shell's {stdout:, stderr:, exit_code:}) as attachments.
                content = result.is_a?(String) ? result : result.to_s

                # Universal truncation safety net — skip if already truncated
                unless Brute::Truncation.already_truncated?(content)
                  content = Brute::Truncation.truncate(content)
                end

                results << [id, tool_call, content]
              rescue => e
                # Capture the error as a tool result so the LLM can see it
                # and reason about the failure, rather than crashing the
                # entire middleware chain.
                env[:events] << { type: :error, data: { error: e, message: e.message } }
                results << [id, tool_call, "Error: #{e.class}: #{e.message}"]
              end
            end

            barrier.wait
          ensure
            barrier&.cancel
          end

          # Append events and messages in the original tool_call order so the
          # LLM sees a deterministic sequence regardless of completion order.
          order = tools_to_run.keys
          results.sort_by! { |id, _, _| order.index(id) }

          results.each do |_id, tool_call, content|
            env[:events] << { type: :tool_result, data: { name: tool_call.name, content: content } }
            env[:messages] << RubyLLM::Message.new(role: :tool, content: content, tool_call_id: tool_call.id)
          end
        end

        return env
      end

      private

        def pending_tool_calls(message)
          message.tool_calls.to_h.reject { |_id, tc| tc.name == "question" }
        end

        def resolve_tools(tools)
          tools.each_with_object({}) do |tool, hash|
            instance = tool.is_a?(Class) ? tool.new : tool
            instance = instance.to_ruby_llm if instance.respond_to?(:to_ruby_llm)
            hash[instance.name.to_sym] = instance
          end
        end

        def on_tool_call_start_event(pending_tools)
          {
            type: :tool_call_start,
            data: pending_tools.map { |_id, tc|
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

test do
  require "brute/session"
  require "brute/truncation"

  it "passes through when no tool calls pending" do
    inner = ->(env) {
      env[:messages] << RubyLLM::Message.new(role: :assistant, content: "hi")
    }
    mw = Brute::Middleware::ToolCall.new(inner)
    env = {
      messages: Brute::Session.new,
      tools: [],
      events: [],
    }
    env[:messages].user("hello")
    mw.call(env)
    env[:messages].last.content.should == "hi"
  end

  # --- Universal output truncation ---

  it "truncates large tool results via Truncation" do
    # A fake tool that returns a huge string
    big_tool = Class.new(RubyLLM::Tool) do
      description "test tool"
      param :input, type: "string", desc: "input"
      def name; "big_tool"; end
      def execute(input:)
        "line\n" * 3000
      end
    end

    call_id = "tc_1"
    tool_calls = {
      call_id => RubyLLM::ToolCall.new(
        id: call_id,
        name: "big_tool",
        arguments: { "input" => "go" },
      )
    }

    inner = ->(env) {
      env[:messages] << RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls)
    }
    mw = Brute::Middleware::ToolCall.new(inner)
    env = {
      messages: Brute::Session.new,
      tools: [big_tool],
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
    pre_truncated_tool = Class.new(RubyLLM::Tool) do
      description "test tool"
      param :input, type: "string", desc: "input"
      def name; "pre_truncated_tool"; end
      def execute(input:)
        "some result\n[Output truncated: showing 100 of 5000 lines]"
      end
    end

    call_id = "tc_2"
    tool_calls = {
      call_id => RubyLLM::ToolCall.new(
        id: call_id,
        name: "pre_truncated_tool",
        arguments: { "input" => "go" },
      )
    }

    inner = ->(env) {
      env[:messages] << RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls)
    }
    mw = Brute::Middleware::ToolCall.new(inner)
    env = {
      messages: Brute::Session.new,
      tools: [pre_truncated_tool],
      events: [],
    }
    env[:messages].user("hello")
    mw.call(env)

    tool_msg = env[:messages].select { |m| m.role == :tool }.last
    # Should contain exactly one truncation marker, not two
    tool_msg.content.scan(/Output truncated/).size.should == 1
  end
end
