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

  turn = nil
  saved_messages = nil
  build_turn = -> {
    return turn if turn

    saved_messages = nil
    session = Brute::Store::Session.new
    session.define_singleton_method(:save_messages) { |m| saved_messages = m }

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::SessionPersistence, session: session
      run ->(_env) { MockResponse.new(content: "saved response") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: session,
      pipeline: pipeline,
      input: "hi",
    )
  }

  it "returns the response unchanged" do
    build_turn.call
    turn.result.content.should == "saved response"
  end

  it "calls save_messages" do
    build_turn.call
    saved_messages.should.not.be.nil
  end

  it "does not propagate session save failures" do
    failing_session = Brute::Store::Session.new
    failing_session.define_singleton_method(:save_messages) { |_| raise "disk full" }

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::SessionPersistence, session: failing_session
      run ->(_env) { MockResponse.new(content: "ok") }
    end

    step = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: failing_session,
      pipeline: pipeline,
      input: "hi",
    )
    step.state.should == :completed
  end
end
