# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Checks context size after each LLM call and triggers compaction
    # when thresholds are exceeded.
    #
    # Runs POST-call: inspects message count and token usage. If compaction
    # is needed, summarizes older messages and replaces env[:messages] with
    # the summary so the next LLM call starts with a compact history.
    #
    class CompactionCheck < Base
      def initialize(app, compactor: nil, system_prompt:, **compactor_opts)
        super(app)
        @compactor = compactor
        @compactor_opts = compactor_opts
        @system_prompt = system_prompt
      end

      def call(env)
        response = @app.call(env)

        @compactor ||= Compactor.new(env[:provider], **@compactor_opts)

        messages = env[:messages]
        usage = env[:metadata].dig(:tokens, :last_call)

        if @compactor.should_compact?(messages, usage: usage)
          result = @compactor.compact(messages)
          if result
            summary_text, _recent = result
            env[:metadata][:compaction] = {
              messages_before: messages.size,
              timestamp: Time.now.iso8601,
            }
            # Replace the message history with the summary
            env[:messages] = [
              LLM::Message.new(:system, @system_prompt),
              LLM::Message.new(:user, "[Previous conversation summary]\n\n#{summary_text}"),
            ]
          end
        end

        response
      end

      # Context compaction service. When the conversation grows past configurable
      # thresholds, older messages are summarized into a condensed form and the
      # original messages are dropped, keeping the context window manageable.
      class Compactor
        DEFAULTS = {
          token_threshold: 100_000,   # Compact when estimated tokens exceed this
          message_threshold: 200,     # Compact when message count exceeds this
          retention_window: 6,        # Minimum recent messages to always keep
          summary_model: nil,         # Model for summarization (uses agent's model if nil)
        }.freeze

        attr_reader :config

        def initialize(provider, **opts)
          @provider = provider
          @config = DEFAULTS.merge(opts)
        end

        # Check whether compaction should run based on current context state.
        def should_compact?(messages, usage: nil)
          return true if messages.size > @config[:message_threshold]
          return true if usage && (usage[:total] || 0) > @config[:token_threshold]
          false
        end

        # Compact the message history by summarizing older messages.
        #
        # Returns [summary_message, kept_messages] — the caller rebuilds
        # the context from these.
        def compact(messages)
          total = messages.size
          keep_count = [@config[:retention_window], total].min
          return nil if total <= keep_count

          old_messages = messages[0...(total - keep_count)]
          recent_messages = messages[(total - keep_count)..]

          summary_text = summarize(old_messages)

          [summary_text, recent_messages]
        end

        private

        def summarize(messages)
          # Build a condensed representation of the conversation for the summarizer
          conversation_text = messages.map { |m|
            role = if m.respond_to?(:role)
              m.role.to_s
            else
              "unknown"
            end
            content = if m.respond_to?(:content)
              m.content.to_s[0..1000]
            else
              m.to_s[0..1000]
            end

            # Include tool call info for assistant messages
            tool_info = ""
            if m.respond_to?(:functions) && m.functions&.any?
              calls = m.functions.map { |f| "#{f.name}(#{f.arguments.to_s[0..200]})" }
              tool_info = " [tools: #{calls.join(", ")}]"
            end

            "#{role}:#{tool_info} #{content}"
          }.join("\n---\n")

          prompt = <<~PROMPT
            Summarize this conversation history for context continuity. The summary will replace
            these messages in the context window, so include everything the agent needs to continue
            working effectively.

            Structure your summary as:
            ## Goal
            What the user asked for.

            ## Progress
            - Files read, created, or modified (list paths)
            - Commands executed and their outcomes
            - Key decisions made

            ## Current State
            Where things stand right now — what's done and what remains.

            ## Next Steps
            What should happen next based on the conversation.

            ---
            CONVERSATION:
            #{conversation_text}
          PROMPT

          model = @config[:summary_model] || "claude-sonnet-4-20250514"
          res = @provider.complete(prompt, model: model)
          res.content
        end
      end
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  def make_compactor(should: false, result: nil)
    Object.new.tap do |c|
      c.define_singleton_method(:should_compact?) { |_msgs, **_| should }
      c.define_singleton_method(:compact) { |_msgs| result }
    end
  end

  it "passes the response through when compaction is not needed" do
    response = MockResponse.new(content: "compaction response")
    compactor = make_compactor(should: false)
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { response }, compactor: compactor, system_prompt: "sys")
    result = middleware.call(build_env)
    result.should == response
  end

  it "does not set compaction metadata when not needed" do
    compactor = make_compactor(should: false)
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { MockResponse.new }, compactor: compactor, system_prompt: "sys")
    env = build_env
    middleware.call(env)
    env[:metadata][:compaction].should.be.nil
  end

  it "replaces messages with summary when compaction triggers" do
    compactor = make_compactor(should: true, result: ["Summary of conversation", []])
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { MockResponse.new }, compactor: compactor, system_prompt: "sys")
    env = build_env(messages: [LLM::Message.new(:user, "hello"), LLM::Message.new(:assistant, "hi"), LLM::Message.new(:user, "how")])
    middleware.call(env)
    env[:metadata][:compaction][:messages_before].should == 3
  end

  it "creates two messages after compaction" do
    compactor = make_compactor(should: true, result: ["Summary", []])
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { MockResponse.new }, compactor: compactor, system_prompt: "sys")
    env = build_env(messages: [LLM::Message.new(:user, "hello")])
    middleware.call(env)
    env[:messages].size.should == 2
  end

  it "handles compactor returning nil gracefully" do
    compactor = make_compactor(should: true, result: nil)
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { MockResponse.new }, compactor: compactor, system_prompt: "sys")
    env = build_env(messages: [LLM::Message.new(:user, "hello")])
    middleware.call(env)
    env[:metadata][:compaction].should.be.nil
  end

  # ── Compactor#should_compact? ────────────────────────────────────

  it "should_compact? returns false when under both thresholds" do
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new)
    usage = { input: 50, output: 30, total: 80 }
    compactor.should_compact?([], usage: usage).should == false
  end

  it "should_compact? returns true when message count exceeds threshold" do
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new, message_threshold: 5)
    messages = 6.times.map { LLM::Message.new(:user, "msg") }
    compactor.should_compact?(messages).should == true
  end

  it "should_compact? returns true when token usage exceeds threshold" do
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new, token_threshold: 100)
    usage = { input: 80, output: 30, total: 110 }
    compactor.should_compact?([], usage: usage).should == true
  end

  it "should_compact? returns false when token usage is under threshold" do
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new, token_threshold: 200)
    usage = { input: 80, output: 30, total: 110 }
    compactor.should_compact?([], usage: usage).should == false
  end

  it "should_compact? returns false when usage is nil" do
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new)
    compactor.should_compact?([], usage: nil).should == false
  end

  it "should_compact? handles usage hash from TokenTracking middleware" do
    # This is the exact shape TokenTracking produces at env[:metadata][:tokens][:last_call]
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new, token_threshold: 100_000)
    usage = { input: 60_000, output: 50_000, total: 110_000 }
    compactor.should_compact?([], usage: usage).should == true
  end

  it "should_compact? respects custom message_threshold" do
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new, message_threshold: 3)
    messages = 4.times.map { LLM::Message.new(:user, "msg") }
    compactor.should_compact?(messages).should == true
  end

  # ── Compactor#compact ────────────────────────────────────────────

  it "compact returns nil when messages fit within retention_window" do
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new, retention_window: 6)
    messages = 4.times.map { LLM::Message.new(:user, "msg") }
    compactor.compact(messages).should.be.nil
  end

  it "compact returns nil when messages equal retention_window" do
    compactor = Brute::Middleware::CompactionCheck::Compactor.new(MockProvider.new, retention_window: 3)
    messages = 3.times.map { LLM::Message.new(:user, "msg") }
    compactor.compact(messages).should.be.nil
  end

  it "compact splits messages and returns [summary, recent]" do
    # Provider whose complete() returns a canned summary
    summary_provider = MockProvider.new
    summary_provider.define_singleton_method(:complete) { |*_args, **_kw| MockResponse.new(content: "Summary of old messages") }

    compactor = Brute::Middleware::CompactionCheck::Compactor.new(summary_provider, retention_window: 2)
    messages = 5.times.map { |i| LLM::Message.new(:user, "msg #{i}") }
    result = compactor.compact(messages)
    result.should.not.be.nil
    summary, recent = result
    summary.should == "Summary of old messages"
    recent.size.should == 2
  end

  it "compact keeps the most recent messages in the retained portion" do
    summary_provider = MockProvider.new
    summary_provider.define_singleton_method(:complete) { |*_args, **_kw| MockResponse.new(content: "sum") }

    compactor = Brute::Middleware::CompactionCheck::Compactor.new(summary_provider, retention_window: 2)
    messages = 5.times.map { |i| LLM::Message.new(:user, "msg #{i}") }
    _, recent = compactor.compact(messages)
    recent.map(&:content).should == ["msg 3", "msg 4"]
  end
end
