# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "../compaction"

module PrimeAgent
  module Middleware
    # Compaction — per-iteration middleware (inside the loop, below
    # MaxIterations). The port of prime-agent's auto-compaction
    # (core/compaction/ + agent-session.ts _checkCompaction): all three
    # upstream triggers are implemented.
    #
    #   threshold  — after each turn boundary (last message is an assistant
    #                text answer), compact when
    #                tokens > context_window - reserve_tokens (16384).
    #                Tokens come from PrimeAgent::Compaction's estimator
    #                (last-usage + chars/4 tail; brute's transport carries no
    #                per-message usage, so this is the estimate path — the
    #                same state upstream is in right after a compaction).
    #                Disabled when context_window is nil/<= 0 (upstream's
    #                contextWindow <= 0 guard) — wire BRUTE_CONTEXT_WINDOW.
    #   overflow   — the provider call raises a context-overflow error:
    #                compact, then retry the inner stack ONCE (upstream's
    #                single compact-and-retry attempt). The flag resets when
    #                a new user message starts a turn.
    #   requested  — the kernel's `compact.run(instructions)` writes
    #                <request_path> (atomically, like refine.run); drained at
    #                the next turn boundary and never mid-cell.
    #
    # Compacting replaces the summarized region with one user message
    # (Compaction::SUMMARY_PREFIX + summary + SUMMARY_SUFFIX), preserving
    # system messages and the recent ~keep_recent_tokens (20000) tail; the
    # summary carries cumulative <modified-files> tracking fed by the edit
    # skill's diff displays. After a compaction, status percent reads null
    # once (upstream: unknown until the next model response).
    #
    # Status is published to <status_path> every iteration so the kernel's
    # `compact.status` can read {tokens, context_window, percent, scheduled}.
    class Compaction
      # Context-overflow fingerprints across providers (upstream classifies
      # these as context-overflow, e.g. a 413 or context_length_exceeded).
      OVERFLOW_PATTERN = /context.?length|context.?window|maximum context|too many tokens|prompt is too long|request entity too large|\b413\b/i

      def initialize(app, llm:, context_window: nil, enabled: true,
                     reserve_tokens: PrimeAgent::Compaction::DEFAULT_SETTINGS.reserve_tokens,
                     keep_recent_tokens: PrimeAgent::Compaction::DEFAULT_SETTINGS.keep_recent_tokens,
                     request_path: nil, status_path: nil)
        @app = app
        @llm = llm
        @context_window = context_window.to_i
        @settings = PrimeAgent::Compaction::Settings.new(
          enabled: enabled,
          reserve_tokens: reserve_tokens,
          keep_recent_tokens: keep_recent_tokens,
        )
        @request_path = request_path
        @status_path = status_path
        @boundary = nil          # { summary:, summary_message:, first_kept_message:, modified_files: }
        @overflow_retried = false
        @last_user_message = nil
        @percent_nil_once = false
      end

      def call(env)
        reset_overflow_retry_if_new_turn(env)

        begin
          @app.call(env)
        rescue StandardError => error
          raise unless @settings.enabled && !@overflow_retried && error.message.match?(OVERFLOW_PATTERN)

          @overflow_retried = true
          compacted = run_compaction(env, custom_instructions: nil)
          raise unless compacted

          @app.call(env) # exactly one compact-and-retry attempt
        end

        after_turn(env)
        write_status(env)
        env
      end

      private

      # Turn boundary = the model answered with text (the loop will stop).
      # Requested compaction wins over the threshold check, matching
      # upstream's agent_end ordering (overflow -> requested -> threshold).
      def after_turn(env)
        last = env[:messages].last
        return unless last && last.role == :assistant

        request = drain_request
        if request[:found]
          run_compaction(env, custom_instructions: request[:instructions])
          return
        end

        tokens = current_tokens(env)
        run_compaction(env, custom_instructions: nil) if PrimeAgent::Compaction.should_compact?(tokens, @context_window, @settings)
      end

      def run_compaction(env, custom_instructions:)
        preparation = PrimeAgent::Compaction.prepare_compaction(
          env[:messages], settings: @settings, boundary: @boundary,
        )
        return false unless preparation

        result = PrimeAgent::Compaction.compact(preparation, llm: @llm, custom_instructions: custom_instructions)

        summary_message = Brute::Message.new(
          role: :user,
          content: "#{PrimeAgent::Compaction::SUMMARY_PREFIX}#{result[:summary]}#{PrimeAgent::Compaction::SUMMARY_SUFFIX}",
        )
        kept = env[:messages][preparation.first_kept_index..] || []
        system = env[:messages].select { |message| message.role == :system }
        env[:messages].replace(system + [summary_message] + kept)

        @boundary = {
          summary: result[:summary],
          summary_message: summary_message,
          first_kept_message: kept.first,
          modified_files: result[:modified_files],
        }
        @percent_nil_once = true
        (env[:events] ||= []) << {
          type: :compaction,
          data: { tokens_before: result[:tokens_before], split_turn: preparation.split_turn? },
        }
        true
      end

      def drain_request
        return { found: false } unless @request_path && File.exist?(@request_path)

        request = JSON.parse(File.read(@request_path))
        File.delete(@request_path)
        { found: true, instructions: request["instructions"] }
      rescue JSON::ParserError
        File.delete(@request_path)
        { found: true, instructions: nil }
      end

      # The threshold's token count: the provider's reported total when
      # UsageAttribution published one (upstream's calculateContextTokens on
      # the last assistant usage), else the chars/4 estimate.
      def current_tokens(env)
        real = env[:metadata] && env[:metadata][:last_context_tokens]
        return real if real

        conversation = env[:messages].reject { |message| message.role == :system }
        PrimeAgent::Compaction.estimate_context_tokens(conversation).tokens
      end

      def reset_overflow_retry_if_new_turn(env)
        last_user = env[:messages].reverse.find { |message| message.role == :user }
        return if last_user.equal?(@last_user_message)

        @last_user_message = last_user
        @overflow_retried = false
      end

      def write_status(env)
        return unless @status_path

        tokens = current_tokens(env)
        percent =
          if @percent_nil_once || @context_window <= 0
            @percent_nil_once = false
            nil
          else
            (tokens.to_f / @context_window * 100).round(1)
          end
        status = {
          "tokens" => tokens,
          "context_window" => @context_window.positive? ? @context_window : nil,
          "percent" => percent,
          "scheduled" => @request_path ? File.exist?(@request_path) : false,
        }
        dir = File.dirname(@status_path)
        FileUtils.mkdir_p(dir)
        tmp = "#{@status_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(status)}\n")
        File.rename(tmp, @status_path)
      rescue StandardError
        nil # status is best-effort; it must never break a turn
      end
    end
  end
end

__END__

describe "prime_agent/middleware/compaction" do
  require "brute/messages"
  require "tmpdir"

  SUMMARY = "## Goal\n- do the thing"

  def build(context_window: 0, keep_recent_tokens: 20_000, reserve_tokens: 16_384, llm: nil, **opts)
    summaries = []
    llm ||= lambda do |system:, user:, max_tokens:|
      summaries << user
      SUMMARY
    end
    app = ->(env) { env[:messages].assistant("final answer"); env }
    middleware = PrimeAgent::Middleware::Compaction.new(
      app, llm: llm, context_window: context_window,
      keep_recent_tokens: keep_recent_tokens, reserve_tokens: reserve_tokens, **opts,
    )
    [middleware, summaries]
  end

  def conversation(messages)
    env = { messages: Brute.log, events: [] }
    env[:messages].system("you are a test agent")
    env[:messages].user("do the thing")
    yield env[:messages] if block_given?
    env
  end

  it "does nothing under the threshold" do
    middleware, = build(context_window: 1_000_000)
    env = conversation([])
    middleware.call(env)
    env[:messages].map(&:role).should == [:system, :user, :assistant]
  end

  it "compacts at the turn boundary when over the threshold, preserving system and the kept tail" do
    middleware, summaries = build(context_window: 200, keep_recent_tokens: 10, reserve_tokens: 50)
    env = conversation([]) do |m|
      m.assistant("working on it")
      m << Brute::Message.new(role: :tool, content: "x" * 800, tool_call_id: "t1")
      m.user("and another thing")
    end
    middleware.call(env)

    roles = env[:messages].map(&:role)
    roles.first.should == :system
    roles[1].should == :user
    summary = env[:messages][1]
    summary.content.should.start_with PrimeAgent::Compaction::SUMMARY_PREFIX
    summary.content.should.include SUMMARY
    summary.content.should.end_with PrimeAgent::Compaction::SUMMARY_SUFFIX
    env[:messages].last.content.should == "final answer"
    env[:messages].none? { |m| m.content.to_s.include?("x" * 100) }.should.be.true
    summaries.length.should == 1
    summaries.first.should.include "<conversation>"
    summaries.first.should.include "[User]: do the thing"
    env[:events].last[:type].should == :compaction
  end

  it "is a no-op when everything fits and there is nothing to summarize" do
    middleware, summaries = build(context_window: 10, keep_recent_tokens: 100_000)
    env = conversation([])
    middleware.call(env)
    summaries.should.be.empty
    env[:messages].map(&:role).should == [:system, :user, :assistant]
  end

  it "drains a kernel compact.run request with its instructions at the turn boundary" do
    Dir.mktmpdir do |dir|
      request_path = File.join(dir, "compact_request.json")
      File.write(request_path, JSON.generate("instructions" => "keep the failing tests"))
      middleware, summaries = build(context_window: 0, keep_recent_tokens: 10, reserve_tokens: 50,
                                    request_path: request_path,
                                    status_path: File.join(dir, "compact_status.json"))
      env = conversation([]) do |m|
        m.assistant("big context #{"y" * 300}")
        m << Brute::Message.new(role: :tool, content: "z" * 800, tool_call_id: "t1")
        m.user("follow up question")
      end
      middleware.call(env)

      File.exist?(request_path).should.be.false
      summaries.first.should.include "<user-instructions>"
      summaries.first.should.include "keep the failing tests"
      env[:messages][1].content.should.include SUMMARY
    end
  end

  it "tracks modified files from edit diff displays into the summary" do
    middleware, = build(context_window: 200, keep_recent_tokens: 10, reserve_tokens: 50)
    env = conversation([]) do |m|
      m.assistant("editing #{"e" * 700}")
      m << Brute::Message.new(role: :tool, content: "Edited /app/a.rb\ndiff /app/a.rb:2\n- two\n+ TWO", tool_call_id: "t1")
      m.user("looks good, continue")
    end
    middleware.call(env)
    env[:messages][1].content.should.include "<modified-files>"
    env[:messages][1].content.should.include "/app/a.rb"
  end

  it "merges into the previous summary on the second compaction" do
    middleware, summaries = build(context_window: 200, keep_recent_tokens: 10, reserve_tokens: 50)
    env = conversation([]) { |m| m.assistant("first big #{"a" * 700}") }
    middleware.call(env)
    env[:messages].assistant("small step")
    env[:messages].user("next task #{"n" * 700}")
    middleware.call(env)

    summaries.length.should == 2
    summaries.last.should.include "<previous-summary>"
    summaries.last.should.include SUMMARY
    env[:messages].count { |m| m.content.to_s.include?("compacted into the following summary") }.should == 1
  end

  it "retries exactly once after a context-overflow error" do
    calls = 0
    llm = ->(system:, user:, max_tokens:) { SUMMARY }
    app = lambda do |env|
      calls += 1
      raise "413 Request Entity Too Large: maximum context length exceeded" if calls == 1

      env[:messages].assistant("recovered")
      env
    end
    middleware = PrimeAgent::Middleware::Compaction.new(
      app, llm: llm, context_window: 200, keep_recent_tokens: 10, reserve_tokens: 50,
    )
    env = conversation([]) { |m| m.assistant("big #{"z" * 300}") }
    middleware.call(env)
    calls.should == 2
    env[:messages].last.content.should == "recovered"
  end

  it "prefers the provider's reported context total over the estimate" do
    app = lambda do |env|
      (env[:metadata] ||= {})[:last_context_tokens] = 190 # tiny log, huge real context
      env[:messages].assistant("final answer")
      env
    end
    llm = ->(system:, user:, max_tokens:) { SUMMARY }
    middleware = PrimeAgent::Middleware::Compaction.new(
      app, llm: llm, context_window: 200, keep_recent_tokens: 10, reserve_tokens: 50,
    )
    env = conversation([]) { |m| m.assistant("prior work #{"p" * 400}") }
    middleware.call(env)
    # 190 > 200 - 50: compacted even though the chars/4 estimate is ~10
    env[:messages].any? { |m| m.content.to_s.include?("compacted into the following summary") }.should.be.true
  end

  it "re-raises a non-overflow error without compacting" do
    llm = ->(system:, user:, max_tokens:) { raise "must not be called" }
    app = ->(_env) { raise "some other failure" }
    middleware = PrimeAgent::Middleware::Compaction.new(app, llm: llm, context_window: 200)
    env = conversation([])
    lambda { middleware.call(env) }.should.raise(RuntimeError)
  end

  it "publishes compact.status fields, percent null once after a compaction" do
    Dir.mktmpdir do |dir|
      status_path = File.join(dir, "compact_status.json")
      middleware, = build(context_window: 10_000, status_path: status_path)
      env = conversation([])
      middleware.call(env)
      status = JSON.parse(File.read(status_path))
      status["context_window"].should == 10_000
      status["tokens"].should.be.kind_of Integer
      status["percent"].should.be.kind_of Numeric
      status["scheduled"].should.be.false

      # Force a compaction; the status written during that call reports nil percent.
      small, = build(context_window: 100, keep_recent_tokens: 10, reserve_tokens: 50, status_path: status_path)
      env2 = conversation([]) { |m| m.assistant("big #{"q" * 300}") }
      small.call(env2)
      status2 = JSON.parse(File.read(status_path))
      status2["percent"].should.be.nil
    end
  end
end
