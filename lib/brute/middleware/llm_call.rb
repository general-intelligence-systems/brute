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
        ctx = build_context(env)

        # Load existing conversation history into the ephemeral context
        ctx.messages.concat(env[:messages])

        response = ctx.talk(env[:input])

        # Extract new messages appended by talk() and store them
        new_messages = ctx.messages.to_a.drop(env[:messages].size)
        env[:messages].concat(new_messages)

        # Stash pending functions for the agent loop
        env[:pending_functions] = ctx.functions.to_a

        # Only fire on_content post-hoc when NOT streaming
        # (streaming delivers chunks incrementally via AgentStream)
        unless env[:streaming]
          if (cb = env.dig(:callbacks, :on_content)) && response
            text = safe_content(response)
            cb.call(text) if text
          end
        end

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
end
