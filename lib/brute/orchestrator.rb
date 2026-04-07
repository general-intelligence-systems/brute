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
  # Tool execution is always deferred until after the LLM response (including
  # streaming) completes. Tools then run concurrently with each other via
  # Async::Barrier. on_tool_call_start fires once with the full batch before
  # execution begins; on_tool_result fires per-tool as each finishes.
  #
  class Orchestrator
    MAX_REQUESTS_PER_TURN = 100

    attr_reader :context, :session, :pipeline, :env, :barrier, :message_store

    def initialize(
      provider:,
      model: nil,
      tools: Brute::TOOLS,
      cwd: Dir.pwd,
      session: nil,
      compactor_opts: {},
      reasoning: {},
      agent_name: nil,
      on_content: nil,
      on_reasoning: nil,
      on_tool_call_start: nil,
      on_tool_result: nil,
      on_question: nil,
      logger: nil
    )
      @provider = provider
      @model = model
      @agent_name = agent_name
      @tool_classes = tools
      @cwd = cwd
      @session = session || Session.new
      @logger = logger || Logger.new($stderr, level: Logger::INFO)
      @message_store = @session.message_store

      # Build system prompt via deferred builder
      @system_prompt_builder = SystemPrompt.default
      @system_prompt = @system_prompt_builder.prepare(
        provider_name: @provider&.name,
        model_name: @model || @provider&.default_model,
        cwd: @cwd,
        custom_rules: load_custom_rules,
        agent: @agent_name,
      ).to_s

      # Initialize the LLM context (with streaming when callbacks provided)
      @stream = if on_content || on_reasoning
        AgentStream.new(
          on_content: on_content,
          on_reasoning: on_reasoning,
          on_question: on_question,
        )
      end
      ctx_opts = { tools: @tool_classes }
      ctx_opts[:model]  = @model  if @model
      ctx_opts[:stream] = @stream if @stream
      @context = LLM::Context.new(@provider, **ctx_opts)

      # Build the middleware pipeline
      compactor = Compactor.new(provider, **compactor_opts)
      @pipeline = build_pipeline(
        compactor: compactor,
        session: @session,
        logger: @logger,
        reasoning: reasoning,
        message_store: @message_store,
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
          on_tool_call_start: on_tool_call_start,
          on_tool_result: on_tool_result,
          on_question: on_question,
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
        # Collect pending tools from either source:
        # - Streaming: AgentStream deferred tools (collected during stream)
        # - Non-streaming: ctx.functions (populated by llm.rb after response)
        pending = collect_pending_tools
        break if pending.empty?

        # Fire on_tool_call_start ONCE with the full batch
        on_start = @env.dig(:callbacks, :on_tool_call_start)
        on_start&.call(pending.map { |tool, _| { name: tool.name, arguments: tool.arguments } })

        # Separate errors (tool not found) from executable tools
        errors = pending.select { |_, err| err }
        executable = pending.reject { |_, err| err }.map(&:first)

        # Execute tools concurrently, collect results
        results = execute_tool_calls(executable)

        # Append error results (tool not found, etc.)
        errors.each do |_, err|
          on_result = @env.dig(:callbacks, :on_tool_result)
          on_result&.call(err.name, result_value(err))
          results << err
        end

        # Send results back through the pipeline
        @env[:input] = results
        @env[:tool_results] = extract_tool_result_pairs(results)
        last_response = @pipeline.call(@env)
        sync_context!

        @request_count += 1

        # Check limits
        break if !has_pending_tools?
        break if @request_count >= MAX_REQUESTS_PER_TURN
        break if @env[:metadata][:tool_error_limit_reached]
      end

      last_response
    end

    private

    # ------------------------------------------------------------------
    # Pipeline construction
    # ------------------------------------------------------------------

    def build_pipeline(compactor:, session:, logger:, reasoning:, message_store:)
      sys_prompt = @system_prompt
      tools = @tool_classes
      stream = @stream

      Pipeline.new do
        # OTel span lifecycle (outermost — creates env[:span])
        use Middleware::OTel::Span

        # Timing and logging
        use Middleware::Tracing, logger: logger

        # OTel: record tool results being sent back (pre-call)
        use Middleware::OTel::ToolResults

        # Retry transient errors (wraps everything below)
        use Middleware::Retry

        # Save after each successful LLM call
        use Middleware::SessionPersistence, session: session

        # Record structured messages in OpenCode {info, parts} format
        use Middleware::MessageTracking, store: message_store

        # Track cumulative token usage
        use Middleware::TokenTracking

        # OTel: record token usage from response (post-call)
        use Middleware::OTel::TokenUsage

        # Check context size and compact if needed
        use Middleware::CompactionCheck,
          compactor: compactor,
          system_prompt: sys_prompt,
          tools: tools,
          stream: stream

        # Track per-tool errors
        use Middleware::ToolErrorTracking

        # Detect and break doom loops (pre-call)
        use Middleware::DoomLoopDetection

        # Handle reasoning params and model-switch normalization (pre-call)
        use Middleware::ReasoningNormalizer, **reasoning unless reasoning.empty?

        # Guard against tool-only responses dropping the assistant message
        use Middleware::ToolUseGuard

        # OTel: record tool calls the LLM requested (post-call, after ToolUseGuard)
        use Middleware::OTel::ToolCalls

        # Innermost: the actual LLM call
        run Middleware::LLMCall.new
      end
    end

    # ------------------------------------------------------------------
    # Pending tool collection
    # ------------------------------------------------------------------

    # Check whether there are pending tools without consuming them.
    def has_pending_tools?
      return true if @stream&.pending_tools&.any?
      return true if @context.functions.any?
      false
    end

    # Collect pending tools from the stream (streaming) or context (non-streaming).
    # Returns an array of [tool, error_or_nil] pairs.
    # Clears the stream's deferred state after consumption.
    def collect_pending_tools
      if @stream&.pending_tools&.any?
        tools = @stream.pending_tools.dup
        @stream.clear_pending_tools!
        tools
      elsif @context.functions.any?
        @context.functions.to_a.map { |fn| [fn, nil] }
      else
        []
      end
    end

    # ------------------------------------------------------------------
    # Tool execution
    # ------------------------------------------------------------------

    def execute_tool_calls(functions)
      return [] if functions.empty?

      # Questions block execution — they must complete before other tools
      # run, since the LLM may need the answer to inform subsequent work.
      # Execute any question tools first (sequentially), then dispatch
      # the remaining tools concurrently.
      questions, others = functions.partition { |fn| fn.name == "question" }

      results = []
      results.concat(execute_sequential(questions)) if questions.any?
      if others.size <= 1
        results.concat(execute_sequential(others))
      else
        results.concat(execute_parallel(others))
      end
      results
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

      results = Array.new(functions.size)

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
