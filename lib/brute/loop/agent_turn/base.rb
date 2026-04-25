# frozen_string_literal: true

require 'colorize_extended'

module Brute
  module Loop
    module AgentTurn
      # The default implementation. Works for any provider.
      # Provider-specific subclasses override supported_messages
      # and anything else that differs.
      #
      # LLM::Context is built fresh for each pipeline call by the LLMCall
      # middleware. The agent turn owns the conversation state via
      # env[:messages] (an Array<LLM::Message>).
      #
      # Supports two modes:
      #
      #   Non-streaming (default): text arrives after the LLM call completes,
      #   on_content fires post-hoc via LLMCall middleware, tool calls come
      #   from env[:pending_functions].
      #
      #   Streaming: enabled when on_content or on_reasoning callbacks are
      #   present. Text/reasoning fire incrementally via AgentStream. Tool
      #   calls are deferred during the stream and collected afterward from
      #   the stream's pending_tools.
      #
      # Callbacks:
      #
      #   on_content:         ->(text) {}     # text chunk (streaming) or full text (non-streaming)
      #   on_reasoning:       ->(text) {}     # reasoning/thinking chunk (streaming only)
      #   on_tool_call_start: ->(batch) {}    # [{name:, arguments:}, ...] before tool execution
      #   on_tool_result:     ->(name, r) {}  # per-tool, after each completes
      #   on_question:        ->(questions, queue) {}  # interactive; push answers onto queue
      #
      class Base < Step
        attr_reader :agent, :session

        DEFAULT_CALLBACKS = begin
          streaming = false
          {
            on_content: ->(text) {
              unless streaming
                print "#{"[agent]".green} "
                streaming = true
              end
              print text
              $stdout.flush
            },
            on_reasoning: ->(text) {
              unless streaming
                $stderr.print "#{"[thinking]".light_black} "
                streaming = true
              end
              $stderr.print text
              $stderr.flush
            },
            on_error: ->(text) {
              if streaming
                $stderr.print "\n"
                streaming = false
              end
              $stderr.puts "#{"[error]".red} #{text}"
            },
            on_log: ->(text) {
              if streaming
                $stderr.print "\n"
                streaming = false
              end
              $stderr.puts "#{"[info]".blue} #{text}"
            },
            on_tool_call_start: ->(batch) {
              if streaming
                $stderr.print "\n"
                streaming = false
              end
              batch.each { |tc| $stderr.puts "#{"[tool]".yellow} (#{tc[:name]})" }
            },
            on_tool_result: ->(name, _) {
              $stderr.puts "#{"[tool]".yellow} (#{name}) done"
            },
          }.freeze
        end

        def initialize(agent:, session:, pipeline:, input: nil, callbacks: {}, **rest)
          super(**rest)
          @agent     = agent
          @session   = session
          @pipeline  = pipeline
          @input     = input
          @callbacks = DEFAULT_CALLBACKS.merge(callbacks)

          # Create streaming bridge when content or reasoning callbacks are
          # present. The stream is passed into env so LLMCall can wire it
          # into each fresh LLM::Context.
          if @callbacks[:on_content] || @callbacks[:on_reasoning]
            @stream = AgentStream.new(
              on_content:   @callbacks[:on_content],
              on_reasoning: @callbacks[:on_reasoning],
              on_question:  @callbacks[:on_question],
            )
          end
        end

        def perform(task)
          env = build_env
          env[:user_text] = @input
          env[:input] = build_initial_input(@input)
          $stderr.puts "#{"[user]".cyan} #{@input}" if @input
          response = @pipeline.call(env)

          while !env[:should_exit] && env[:tool_results_queue]&.any?
            response = @pipeline.call(env)
          end

          response
        rescue => e
          @callbacks[:on_error]&.call(e.message)
          raise
        end

        # Override in subclasses to filter message types per provider.
        # Default: all messages pass through.
        def supported_messages(messages)
          messages
        end

        # Allow middleware to reset the sub-queue between iterations.
        def reset_jobs!
          @mutex.synchronize { @jobs = nil }
        end

        private

        def build_env
          {
            provider:          @agent.provider,
            model:             @agent.model,
            input:             nil,
            tools:             @agent.tools,
            messages:          [],
            stream:            @stream,
            params:            {},
            metadata:          {},
            tool_results:      nil,
            streaming:         !!@stream,
            callbacks:         @callbacks,
            should_exit:       nil,
            pending_functions: [],
            pending_tools:     [],
            tool_results_queue: nil,
            turn:              self,
          }
        end

        def build_initial_input(user_message)
          sys = @agent.system_prompt
          LLM::Prompt.new(@agent.provider) do |p|
            p.system(sys) if sys
            p.user(user_message) if user_message
          end
        end
      end
    end
  end
end
