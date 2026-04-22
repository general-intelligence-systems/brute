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
      tools: Brute::Tools::ALL,
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

      @system_prompt_builder = SystemPrompt.default
      @system_prompt = @system_prompt_builder.prepare(
        provider_name: @provider&.name,
        model_name: @model || @provider&.default_model,
        cwd: @cwd,
        custom_rules: load_custom_rules,
        agent: @agent_name,
      ).to_s

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
        raise "No LLM provider configured. Set LLM_API_KEY and optionally LLM_PROVIDER (default: opencode_zen)"
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
        use Middleware::OTel::Span
        use Middleware::Tracing, logger: logger
        use Middleware::OTel::ToolResults
        use Middleware::Retry
        use Middleware::SessionPersistence, session: session
        use Middleware::MessageTracking, store: message_store
        use Middleware::TokenTracking
        use Middleware::OTel::TokenUsage
        use Middleware::CompactionCheck,
          compactor: compactor,
          system_prompt: sys_prompt,
          tools: tools,
          stream: stream
        use Middleware::ToolErrorTracking
        use Middleware::DoomLoopDetection
        use Middleware::ReasoningNormalizer, **reasoning unless reasoning.empty?
        use Middleware::ToolUseGuard
        use Middleware::OTel::ToolCalls
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

if __FILE__ == $0
  require_relative "../../spec/spec_helper"

  RSpec.describe Brute::Orchestrator, "system prompt" do
    let(:provider) { MockProvider.new }

    def build_orchestrator(agent_name: nil, cwd: Dir.pwd)
      described_class.new(
        provider: provider,
        model: "test-model",
        tools: [],
        cwd: cwd,
        agent_name: agent_name,
        logger: Logger.new(File::NULL),
      )
    end

    def system_prompt_for(orchestrator)
      orchestrator.instance_variable_get(:@system_prompt)
    end

    # ── Build mode (default) ──

    context "build mode (default, agent_name: nil)" do
      subject(:prompt) { system_prompt_for(build_orchestrator(agent_name: nil)) }

      it "does NOT contain PlanReminder" do
        expect(prompt).not_to include("Plan Mode - System Reminder")
        expect(prompt).not_to include("READ-ONLY")
      end

      it "does NOT contain BuildSwitch" do
        expect(prompt).not_to include("operational mode has changed")
      end

      it "does NOT contain MaxSteps" do
        expect(prompt).not_to include("MAXIMUM STEPS REACHED")
      end

      it "contains identity section" do
        expect(prompt).to include("Brute")
      end

      it "contains environment section" do
        expect(prompt).to include("<env>")
        expect(prompt).to include("Working directory:")
      end
    end

    context "build mode (explicit agent_name: 'build')" do
      subject(:prompt) { system_prompt_for(build_orchestrator(agent_name: "build")) }

      it "does NOT contain PlanReminder" do
        expect(prompt).not_to include("Plan Mode - System Reminder")
        expect(prompt).not_to include("READ-ONLY")
      end

      it "contains identity section" do
        expect(prompt).to include("Brute")
      end
    end

    # ── Plan mode ──

    context "plan mode (agent_name: 'plan')" do
      subject(:prompt) { system_prompt_for(build_orchestrator(agent_name: "plan")) }

      it "includes PlanReminder" do
        expect(prompt).to include("Plan Mode - System Reminder")
        expect(prompt).to include("<system-reminder>")
        expect(prompt).to include("READ-ONLY")
      end

      it "includes the supersede warning" do
        expect(prompt).to include("supersedes any other instructions")
      end

      it "does NOT include BuildSwitch" do
        expect(prompt).not_to include("operational mode has changed")
      end

      it "still includes identity section" do
        expect(prompt).to include("Brute")
      end

      it "still includes environment section" do
        expect(prompt).to include("<env>")
      end
    end

    # ── Switching from plan to build (simulating mid-session agent recreation) ──

    context "switching from plan to build (new orchestrator, same session)" do
      let(:session) { Brute::Session.new }

      it "plan orchestrator has PlanReminder, build orchestrator does not" do
        plan_orch = described_class.new(
          provider: provider,
          model: "test-model",
          tools: [],
          session: session,
          agent_name: "plan",
          logger: Logger.new(File::NULL),
        )
        plan_prompt = system_prompt_for(plan_orch)
        expect(plan_prompt).to include("READ-ONLY")

        build_orch = described_class.new(
          provider: provider,
          model: "test-model",
          tools: [],
          session: session,
          agent_name: "build",
          logger: Logger.new(File::NULL),
        )
        build_prompt = system_prompt_for(build_orch)
        expect(build_prompt).not_to include("READ-ONLY")
        expect(build_prompt).not_to include("Plan Mode")
      end

      it "build orchestrator does NOT contain BuildSwitch (agent_switched never set)" do
        build_orch = described_class.new(
          provider: provider,
          model: "test-model",
          tools: [],
          session: session,
          agent_name: "build",
          logger: Logger.new(File::NULL),
        )
        build_prompt = system_prompt_for(build_orch)
        # This documents the current behavior: BuildSwitch is dead code
        expect(build_prompt).not_to include("operational mode has changed from plan to build")
      end
    end

    context "provider-specific identity text" do
      it "uses mock provider (falls back to default stack)" do
        prompt = system_prompt_for(build_orchestrator)
        # MockProvider.name returns :mock, which isn't a known stack, so falls back to "default"
        expect(prompt).to be_a(String)
        expect(prompt).not_to be_empty
      end
    end

    context "cwd propagation" do
      it "embeds the given cwd in the system prompt" do
        Dir.mktmpdir do |dir|
          prompt = system_prompt_for(build_orchestrator(cwd: dir))
          expect(prompt).to include(dir)
        end
      end
    end
  end
end
