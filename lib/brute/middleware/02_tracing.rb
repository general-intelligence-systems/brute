# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Logs timing and token usage for every LLM call, and tracks cumulative
    # timing data in env[:metadata][:timing].
    #
    # As the outermost middleware, it sees the full pipeline elapsed time per
    # call. It also tracks total wall-clock time across all calls in a turn
    # (including tool execution gaps between LLM calls).
    #
    # A new turn is detected when env[:tool_results] is nil (the agent loop
    # sets this on the first call of each run()).
    #
    # Stores in env[:metadata][:timing]:
    #   total_elapsed:     wall-clock since the turn began (includes tool gaps)
    #   total_llm_elapsed: cumulative time spent inside LLM calls only
    #   llm_call_count:    number of LLM calls so far
    #   last_call_elapsed: duration of the most recent LLM call
    #
    class Tracing < Base
      def initialize(app, logger:)
        super(app)
        @logger = logger
        @call_count = 0
        @total_llm_elapsed = 0.0
        @turn_start = nil
      end

      def call(env)
        @call_count += 1

        # Detect new turn: tool_results is nil on the first pipeline call
        if env[:tool_results].nil?
          @turn_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @total_llm_elapsed = 0.0
        end

        messages = env[:messages]
        provider_name = env[:provider]&.respond_to?(:name) ? env[:provider].name : env[:provider].class.name
        model_name = env[:model] || (env[:provider].default_model rescue "unknown")
        @logger.debug("[brute] LLM call ##{@call_count} [#{provider_name}/#{model_name}] (#{messages.size} messages in context)")

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = @app.call(env)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = now - start

        @total_llm_elapsed += elapsed

        tokens = if response.respond_to?(:usage) && (usage = response.usage)
          read_token(usage, :total_tokens)
        else
          '?'
        end
        @logger.debug("[brute] LLM response ##{@call_count} [#{provider_name}/#{model_name}]: #{tokens} tokens, #{elapsed.round(2)}s")
        env[:callbacks].on_log("LLM response ##{@call_count}: #{tokens} tokens, #{elapsed.round(2)}s") if response

        env[:metadata][:timing] = {
          total_elapsed: now - (@turn_start || start),
          total_llm_elapsed: @total_llm_elapsed,
          llm_call_count: @call_count,
          last_call_elapsed: elapsed
        }

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

  log_output = StringIO.new
  log_messages = []
  turn = nil

  build_turn = -> {
    return turn if turn

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::Tracing, logger: Logger.new(log_output, level: Logger::DEBUG)
      run ->(_env) { MockResponse.new(content: "traced response") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
      callbacks: { on_log: ->(text) { log_messages << text } },
    )
  }

  it "returns the response unchanged" do
    build_turn.call
    turn.result.content.should == "traced response"
  end

  it "logs the LLM call" do
    build_turn.call
    log_output.string.should =~ /LLM call #1/
  end

  it "fires on_log for response" do
    build_turn.call
    log_messages.any? { |m| m =~ /LLM response #1/ }.should.be.true
  end
end
