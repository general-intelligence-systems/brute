# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # The terminal "app" in the pipeline — performs the actual LLM call.
    #
    # Builds a fresh LLM::Context per call from env[:messages], makes the
    # call, extracts new messages back into env[:messages], and stashes
    # pending functions in env[:pending_functions].
    #
    # When streaming, on_content fires incrementally via AgentStream.
    # When not streaming, fires on_content post-hoc with the full text.
    #
    class LLMCall
      def call(env)
        stream = env[:callbacks]

        # First call of a turn — record user message
        if env[:tool_results].nil? && env[:user_text]
          stream.start_user_message(text: env[:user_text])
        end

        # Open assistant message before the call
        model = env[:model] || (env[:provider].default_model rescue nil)
        provider_name = env[:provider]&.class&.name&.split("::")&.last&.downcase
        stream.start_assistant_message(model_id: model&.to_s, provider_id: provider_name)

        ctx = build_context(env)

        # Load existing conversation history into the ephemeral context
        ctx.messages.concat(env[:messages])

        begin
          response = ctx.talk(env[:input])
        rescue => e
          error_type = e.class.name.split('::').last.downcase rescue "unknown"
          error_text = e.message.to_s.gsub(/\s*\n\s*/, ' ').strip
          stream.on_error("(#{error_type}) - #{error_text}")
          env[:messages] << LLM::Message.new(:system, error_text)
          env[:should_exit] = { reason: "llm_error", message: error_text, source: "LLMCall" }
          stream.complete_assistant_message(tokens: nil)
          return nil
        end

        # Extract new messages appended by talk() and store them
        new_messages = ctx.messages.to_a.drop(env[:messages].size)
        env[:messages].concat(new_messages)

        # Stash pending functions for the agent loop
        env[:pending_functions] = ctx.functions.to_a

        # Only fire on_content post-hoc when NOT streaming
        # (streaming delivers chunks incrementally via AgentStream)
        unless env[:streaming]
          if response
            text = safe_content(response)
            stream.on_content(text) if text
          end
        end

        # Finalize assistant message with token usage
        tokens = extract_tokens(env, response)
        stream.complete_assistant_message(tokens: tokens)

        response
      end

      private

      def build_context(env)
        params = {}
        params[:tools]  = env[:tools]   if env[:tools]&.any?
        params[:stream] = env[:stream]  if env[:stream]
        params[:model]  = env[:model]   if env[:model]
        LLM::Context.new(env[:provider], **params)
      end

      # Safely extract text content from an LLM response.
      # Returns nil when the response contains only tool calls (no assistant text),
      # which causes LLM::Contract::Completion#content to raise NoMethodError
      # because messages.find(&:assistant?) returns nil.
      def safe_content(response)
        return nil unless response.respond_to?(:content)
        response.content
      rescue NoMethodError
        nil
      end

      def extract_tokens(env, response)
        meta_tokens = env.dig(:metadata, :tokens, :last_call)
        if meta_tokens
          {
            input: meta_tokens[:input] || 0,
            output: meta_tokens[:output] || 0,
            reasoning: 0,
            cache: { read: 0, write: 0 },
          }
        elsif response.respond_to?(:usage) && (usage = response.usage)
          {
            input: read_token(usage, :input_tokens),
            output: read_token(usage, :output_tokens),
            reasoning: read_token(usage, :reasoning_tokens),
            cache: { read: 0, write: 0 },
          }
        end
      end

      def read_token(usage, method)
        if usage.respond_to?(method)
          usage.send(method).to_i
        elsif usage.respond_to?(:[])
          (usage[method] || usage[method.to_s]).to_i
        else
          0
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

  it "calls the provider and returns a response" do
    provider = MockProvider.new
    middleware = Brute::Middleware::LLMCall.new
    env = build_env(provider: provider, input: "hello", streaming: false)
    response = middleware.call(env)
    response.should.not.be.nil
  end

  it "records a call on the provider" do
    provider = MockProvider.new
    middleware = Brute::Middleware::LLMCall.new
    env = build_env(provider: provider, input: "hello", streaming: false)
    middleware.call(env)
    provider.calls.size.should == 1
  end

  it "appends new messages to env[:messages]" do
    provider = MockProvider.new
    middleware = Brute::Middleware::LLMCall.new
    env = build_env(provider: provider, input: "hello", streaming: false)
    middleware.call(env)
    env[:messages].should.not.be.empty
  end

  it "populates env[:pending_functions] as an Array" do
    provider = MockProvider.new
    middleware = Brute::Middleware::LLMCall.new
    env = build_env(provider: provider, input: "hello", streaming: false)
    middleware.call(env)
    env[:pending_functions].should.be.kind_of(Array)
  end

  it "does not fire on_content callback when streaming" do
    provider = MockProvider.new
    middleware = Brute::Middleware::LLMCall.new
    called = false
    env = build_env(provider: provider, input: "hi", streaming: true, callbacks: { on_content: ->(_) { called = true } })
    middleware.call(env)
    called.should.be.false
  end

  it "preserves existing messages across calls" do
    provider = MockProvider.new
    middleware = Brute::Middleware::LLMCall.new
    existing = LLM::Message.new(:user, "previous")
    env = build_env(provider: provider, input: "hello", streaming: false, messages: [existing])
    middleware.call(env)
    env[:messages].first.should == existing
  end

  it "fires on_error callback on LLM failure" do
    error_received = nil
    callbacks = { on_error: ->(text) { error_received = text } }
    provider = MockProvider.new
    provider.define_singleton_method(:complete) { |*, **| raise "invalid x-api-key" }
    middleware = Brute::Middleware::LLMCall.new
    env = build_env(provider: provider, input: "hello", streaming: false, callbacks: callbacks)
    middleware.call(env)
    error_received.should =~ /invalid x-api-key/
  end

  it "sets should_exit on LLM failure" do
    provider = MockProvider.new
    provider.define_singleton_method(:complete) { |*, **| raise "bad key" }
    middleware = Brute::Middleware::LLMCall.new
    env = build_env(provider: provider, input: "hello", streaming: false)
    middleware.call(env)
    env[:should_exit][:reason].should == "llm_error"
  end
end
