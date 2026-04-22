module Brute
  class Orchestrator
    class Turn
      def initialize(env:, pending:)
        @env = env
        @pending = pending
      end

      def perform
        @env.dig(:callbacks, :on_tool_call_start).then do |on_start|
          on_start&.call(
            @pending.map do |tool, _|
              {
                name: tool.name,
                arguments: tool.arguments
              }
            end
          )
        end

        execute_tool_calls.tap do |results|
          errors.each do |_, err|
            on_result = @env.dig(:callbacks, :on_tool_result)
            on_result&.call(err.name, result_value(err))
            results << err
          end
        end
      end

      def errors = @pending.select { |_, err| err }
      def executable = @pending.reject { |_, err| err }.map(&:first)

      def execute_tool_calls
        if executable.empty?
          []
        else
          # Questions block execution — they must complete before other tools
          # run, since the LLM may need the answer to inform subsequent work.
          # Execute any question tools first (sequentially), then dispatch
          # the remaining tools concurrently.
          questions, others = executable.partition { _1.name == "question" }

          Array.new.tap do |results|
            if questions.any?
              results.concat(execute_sequential(questions))
            end

            if others.size <= 1
              results.concat(execute_sequential(others))
            else
              results.concat(execute_parallel(others))
            end
          end
        end
      end

      # Run a single tool call synchronously.
      def execute_sequential(functions)
        on_result = @env.dig(:callbacks, :on_tool_result)
        on_question = @env.dig(:callbacks, :on_question)

        functions.map do |fn|
          Thread.current[:on_question] = on_question
          result = fn.call
          on_result&.call(fn.name, result_value(result))
          result
        end
      end

      # Run all pending tool calls concurrently via Async::Barrier.
      #
      # Each tool runs in its own fiber. File-mutating tools are safe because
      # they go through FileMutationQueue, whose Mutex is fiber-scheduler-aware
      # in Ruby 3.4 — a fiber blocked on a per-file mutex yields to other
      # fibers instead of blocking the thread.
      #
      # The barrier is stored in @barrier so abort! can cancel in-flight tools.
      #
      def execute_parallel(functions)
        on_result = @env.dig(:callbacks, :on_tool_result)
        on_question = @env.dig(:callbacks, :on_question)

        Array.new(functions.size).tap do |results|
          Async do
            @barrier = Async::Barrier.new

            functions.each_with_index do |fn, i|
              @barrier.async do
                Thread.current[:on_question] = on_question
                results[i] = fn.call
                r = results[i]
                on_result&.call(r.name, result_value(r))
              end
            end

            @barrier.wait
          ensure
            @barrier&.stop
            @barrier = nil
          end
        end
      end
    end
  end
end
