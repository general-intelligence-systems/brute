# frozen_string_literal: true

require "async"
require "async/barrier"

module Brute
  # The core agent loop. Drives the cycle of:
  #
  #   prompt → LLM → tool calls → execute → send results → repeat
  #
  # All cross-cutting concerns (retry, compaction, doom loop detection,
  # token tracking, session persistence, tracing, reasoning) are implemented
  # as Rack-style middleware in the Pipeline. The orchestrator is now a
  # thin loop that:
  #
  #   1. Sends input through the pipeline (which wraps the LLM call)
  #   2. Executes any tool calls the LLM requested
  #   3. Repeats until done or a limit is hit
  #
  class Orchestrator
    MAX_REQUESTS_PER_TURN = 100

    attr_reader :context, :session, :pipeline, :env, :barrier

    def initialize(
      provider:,
      tools: Brute::TOOLS,
      cwd: Dir.pwd,
      session: nil,
      compactor_opts: {},
      reasoning: {},
      on_content: nil,
      on_reasoning: nil,
      on_tool_call: nil,
      on_tool_result: nil,
      logger: nil
    )
      @provider = provider
      @tool_classes = tools
      @cwd = cwd
      @session = session || Session.new
      @logger = logger || Logger.new($stderr, level: Logger::INFO)

      # Build system prompt
      custom_rules = load_custom_rules
      prompt_builder = SystemPrompt.new(cwd: @cwd, tools: @tool_classes, custom_rules: custom_rules)
      @system_prompt = prompt_builder.build

      # Initialize the LLM context (with streaming when callbacks provided)
      @stream = if on_content || on_reasoning
        AgentStream.new(
          on_content: on_content,
          on_reasoning: on_reasoning,
          on_tool_call: on_tool_call,
          on_tool_result: on_tool_result,
        )
      end
      @context = LLM::Context.new(@provider, tools: @tool_classes,
        **(@stream ? {stream: @stream} : {}))

      # Build the middleware pipeline
      compactor = Compactor.new(provider, **compactor_opts)
      @pipeline = build_pipeline(
        compactor: compactor,
        session: @session,
        logger: @logger,
        reasoning: reasoning,
      )

      # The shared env hash — passed to every pipeline.call()
      @env = {
        context: @context,
        provider: @provider,
        tools: @tool_classes,
        input: nil,
        params: {},
        metadata: {},
        tool_results: nil,
        streaming: !!@stream,
        callbacks: {
          on_content: on_content,
          on_reasoning: on_reasoning,
          on_tool_call: on_tool_call,
          on_tool_result: on_tool_result,
        },
      }
    end

    # Run a single user turn. Loops internally until the agent either
    # completes (no more tool calls) or hits a limit.
    #
    # Returns the final assistant response.
    def run(user_message)
      unless @provider
        raise "No LLM provider configured. Set LLM_API_KEY and optionally LLM_PROVIDER (default: anthropic)"
      end

      @request_count = 0

      # Build the initial prompt with system message on first turn
      input = if first_turn?
        @context.prompt do |p|
          p.system @system_prompt
          p.user user_message
        end
      else
        user_message
      end

      # --- First LLM call ---
      @env[:input] = input
      @env[:tool_results] = nil
      last_response = @pipeline.call(@env)
      sync_context!

      # --- Agent loop ---
      loop do
        break if @context.functions.empty?

        # Collect tool results.
        # Streaming: tools already spawned threads during the LLM response — just join them.
        # Non-streaming: execute manually (parallel or sequential).
        results = if @stream && !@stream.queue.empty?
          @context.wait(:thread)
        else
          execute_tool_calls
        end

        # Send results back through the pipeline
        @env[:input] = results
        @env[:tool_results] = extract_tool_result_pairs(results)
        last_response = @pipeline.call(@env)
        sync_context!

        @request_count += 1

        # Check limits
        break if @context.functions.empty?
        break if @request_count >= MAX_REQUESTS_PER_TURN
        break if @env[:metadata][:tool_error_limit_reached]
      end

      last_response
    end

    private

    # ------------------------------------------------------------------
    # Pipeline construction
    # ------------------------------------------------------------------

    def build_pipeline(compactor:, session:, logger:, reasoning:)
      sys_prompt = @system_prompt
      tools = @tool_classes

      Pipeline.new do
        # Outermost: timing and logging (sees total elapsed including retries)
        use Middleware::Tracing, logger: logger

        # Retry transient errors (wraps everything below)
        use Middleware::Retry

        # Save after each successful LLM call
        use Middleware::SessionPersistence, session: session

        # Track cumulative token usage
        use Middleware::TokenTracking

        # Check context size and compact if needed
        use Middleware::CompactionCheck,
          compactor: compactor,
          system_prompt: sys_prompt,
          tools: tools

        # Track per-tool errors
        use Middleware::ToolErrorTracking

        # Detect and break doom loops (pre-call)
        use Middleware::DoomLoopDetection

        # Handle reasoning params and model-switch normalization (pre-call)
        use Middleware::ReasoningNormalizer, **reasoning unless reasoning.empty?

        # Innermost: the actual LLM call
        run Middleware::LLMCall.new
      end
    end

    # ------------------------------------------------------------------
    # Tool execution
    # ------------------------------------------------------------------

    def execute_tool_calls
      pending = @context.functions.to_a
      return execute_sequential(pending) if pending.size <= 1

      execute_parallel(pending)
    end

    # Run a single tool call synchronously.
    def execute_sequential(functions)
      on_call = @env.dig(:callbacks, :on_tool_call)
      on_result = @env.dig(:callbacks, :on_tool_result)

      functions.map do |fn|
        on_call&.call(fn.name, fn.arguments)
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
      on_call = @env.dig(:callbacks, :on_tool_call)
      on_result = @env.dig(:callbacks, :on_tool_result)

      results = Array.new(functions.size)

      Async do
        @barrier = Async::Barrier.new

        functions.each_with_index do |fn, i|
          @barrier.async do
            on_call&.call(fn.name, fn.arguments)
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

      results
    end

    public

    # Cancel any in-flight tool execution. Safe to call from a signal
    # handler, another thread, or an interface layer (TUI, web, RPC).
    #
    # When called, Async::Stop is raised in each running fiber, unwinding
    # through ensure blocks — so FileMutationQueue mutexes release cleanly
    # and SnapshotStore stays consistent.
    #
    def abort!
      @barrier&.stop
    end

    private

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    # After a pipeline call, the compaction middleware may have replaced
    # the context. Sync our local reference.
    def sync_context!
      @context = @env[:context]
    end

    def first_turn?
      @context.messages.to_a.empty?
    end

    def result_value(result)
      result.respond_to?(:value) ? result.value : result
    end

    # Build [name, value] pairs from tool results for ToolErrorTracking.
    def extract_tool_result_pairs(results)
      results.filter_map do |r|
        name = r.respond_to?(:name) ? r.name : "unknown"
        val = result_value(r)
        [name, val]
      end
    end

    # Load AGENTS.md or .brute/rules from the working directory.
    def load_custom_rules
      candidates = [
        File.join(@cwd, "AGENTS.md"),
        File.join(@cwd, ".brute", "rules.md"),
      ]
      found = candidates.find { |p| File.exist?(p) }
      found ? File.read(found) : nil
    end
  end
end
