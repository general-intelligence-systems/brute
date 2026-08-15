# frozen_string_literal: true

require "async"
require "async/barrier"

module Hermes
  module Middleware
    # Turn-level tool dispatcher — brute's Brute::Middleware::ToolPipeline (070),
    # but every tool call is executed through a caller-supplied **custom turn
    # pipeline** (a Brute::Turn::Pipeline carrying the per-call middleware stack,
    # MIDDLEWARE.md §4) instead of running the bare handler.
    #
    #   tools = [...]
    #   pipeline = Brute::Turn::Pipeline.new do
    #     use Hermes::Middleware::Tool::CoerceArgs
    #     # ...
    #   end
    #
    #   Brute.agent
    #     .use(Hermes::Middleware::ToolPipeline, tools: tools, pipeline: pipeline)
    #     .run { |env| ... }
    #
    # The custom pipeline only carries `use` lines — this middleware attaches the
    # terminal app, which dispatches to the tool matched for the call (exposed to
    # the stack as env[:tool], its Brute::Tools::Adapter). Each call's env:
    #
    #   { name:, arguments:, result:, events:, metadata:, tool: }
    #
    # Caveat: the pipeline's middleware instances are shared across concurrent
    # tool calls (parallel barrier) — keep them re-entrant.
    class ToolPipeline
      def initialize(app, tools:, pipeline:)
        @app   = app
        @tools = tools
        @pipeline = pipeline.run ->(env) { env[:result] = env[:tool].call(env[:arguments]) }
      end

      def call(env)
        # env[:tool_free] (set by IterationBudget's grace call) disables tool
        # advertising AND execution for this pass.
        env[:tools] = @tools unless env[:tool_free]
        @app.call(env)

        response = env[:messages].last

        if response.respond_to?(:tool_calls) && response.tool_calls.present?
          tools_to_run = response.tool_calls
          tools_to_run = tools_to_run.values if tools_to_run.respond_to?(:values)
          tools_to_run = Array(tools_to_run).reject { |tc| tc.name == "question" }

          available_tools = Brute::Tools::Adapter.wrap_all(env[:tools])
          # Middleware-provided tools (env[:provided_tools] — memory, todo, …)
          # shadow the statically-listed scaffolds of the same name. This is the
          # agent-state interception seam (hermes' _AGENT_LOOP_TOOLS pattern).
          Array(env[:provided_tools]).each do |tool|
            adapter = Brute::Tools::Adapter.wrap(tool)
            available_tools[adapter.name.to_sym] = adapter
          end

          results = []

          # Async::Barrier blocks until all tasks are complete.
          # Tasks run in parallel.
          Sync do
            barrier = Async::Barrier.new

            tools_to_run.each do |tool_call|
              barrier.async do
                adapter  = available_tools[tool_call.name.to_sym]
                call_env = {
                  name:      adapter.name,
                  arguments: tool_call.arguments,
                  result:    nil,
                  events:    env[:events],
                  metadata:  {},
                  tool:      adapter,
                }

                @pipeline.call(call_env)
                content = call_env[:result]

                # Coerce to String so Hash results serialize predictably.
                content = content.to_s unless content.is_a?(String)

                # Universal truncation safety net — skip if already truncated.
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
            env[:messages] << Brute::Message.new(role: :tool, content: content, tool_call_id: tool_call.id)
          end
        end

        env
      end
    end
  end
end
