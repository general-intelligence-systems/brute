# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Saves the conversation to disk after each LLM call.
    #
    # Runs POST-call: serializes env[:messages] via Session#save_messages.
    # Failures are non-fatal — a broken session save should never crash
    # the agent loop.
    #
    class SessionPersistence < Base
      def initialize(app, session:)
        super(app)
        @session = session
      end

      def call(env)
        response = @app.call(env)

        begin
          @session.save_messages(env[:messages])
        rescue => e
          warn "[brute] Session save failed: #{e.message}"
        end

        response
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

  it "passes the response through unchanged" do
    response = MockResponse.new(content: "saved response")
    session = Struct.new(:saved) { def save_messages(m); self.saved = m; end }.new
    inner_app = ->(_env) { response }
    middleware = Brute::Middleware::SessionPersistence.new(inner_app, session: session)
    result = middleware.call(build_env)
    result.should == response
  end

  it "calls session.save_messages with env messages" do
    response = MockResponse.new(content: "saved response")
    session = Struct.new(:saved) { def save_messages(m); self.saved = m; end }.new
    inner_app = ->(_env) { response }
    middleware = Brute::Middleware::SessionPersistence.new(inner_app, session: session)
    messages = [LLM::Message.new(:user, "hello")]
    middleware.call(build_env(messages: messages))
    session.saved.should == messages
  end

  it "does not propagate session save failures" do
    response = MockResponse.new(content: "saved response")
    session = Object.new
    session.define_singleton_method(:save_messages) { |_| raise RuntimeError, "disk full" }
    inner_app = ->(_env) { response }
    middleware = Brute::Middleware::SessionPersistence.new(inner_app, session: session)
    lambda { middleware.call(build_env) }.should.not.raise
  end
end
