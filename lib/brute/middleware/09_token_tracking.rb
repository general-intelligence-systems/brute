# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Tracks cumulative token usage across all LLM calls in a session.
    #
    # Runs POST-call: reads usage from the response and accumulates totals
    # in env[:metadata]. Also records per-call usage for the most recent call.
    #
    class TokenTracking < Base
      def initialize(app)
        super(app)
        @total_input = 0
        @total_output = 0
        @total_reasoning = 0
        @call_count = 0
      end

      def call(env)
        response = @app.call(env)

        if response.respond_to?(:usage) && (usage = response.usage)
          input  = read_token(usage, :input_tokens)
          output = read_token(usage, :output_tokens)
          reasoning = read_token(usage, :reasoning_tokens)
          total  = read_token(usage, :total_tokens)

          @total_input += input
          @total_output += output
          @total_reasoning += reasoning
          @call_count += 1

          env[:metadata][:tokens] = {
            total_input: @total_input,
            total_output: @total_output,
            total_reasoning: @total_reasoning,
            total: @total_input + @total_output,
            call_count: @call_count,
            last_call: {
              input: input,
              output: output,
              total: total,
            },
          }
        end

        response
      end

      private

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

  turn = nil
  build_turn = -> {
    return turn if turn

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::TokenTracking
      run ->(_env) {
        MockResponse.new(content: "hello",
          usage: LLM::Usage.new(input_tokens: 100, output_tokens: 50, reasoning_tokens: 10, total_tokens: 160))
      }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
  }

  it "returns the response unchanged" do
    build_turn.call
    turn.result.content.should == "hello"
  end

  it "populates total_input tokens" do
    build_turn.call
    turn.env[:metadata][:tokens][:total_input].should == 100
  end

  it "populates total_output tokens" do
    build_turn.call
    turn.env[:metadata][:tokens][:total_output].should == 50
  end

  it "populates total_reasoning tokens" do
    build_turn.call
    turn.env[:metadata][:tokens][:total_reasoning].should == 10
  end

  it "populates call_count" do
    build_turn.call
    turn.env[:metadata][:tokens][:call_count].should == 1
  end

  it "handles a response without usage gracefully" do
    step = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: Brute::Middleware::Stack.new {
        use Brute::Middleware::TokenTracking
        run ->(_env) { Object.new }
      },
      input: "hi",
    )
    step.env[:metadata][:tokens].should.be.nil
  end
end
