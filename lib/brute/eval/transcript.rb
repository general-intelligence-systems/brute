# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/env"

module Brute
  module Eval
    # What one turn did.
    #
    # Every observation comes off the agent's own hooks, so a transcript is
    # what the run itself reported: the tool calls in the order they were
    # made, with the result each came back with, what the model finally said,
    # what the provider charged for it, and how the call failed when it did.
    # Nothing in the agent knows it is being watched.
    #
    #   transcript = Brute::Eval::Transcript.new
    #   transcript.subscribe(agent)
    #   agent.start("what changed?")
    #
    #   transcript.called?("search", "query" => /fed/i)
    #   transcript.before?("read", "write")
    class Transcript
      attr_reader :calls, :usage, :failures
      attr_accessor :seconds, :published, :error

      def initialize
        @calls = []
        @usage = Hash.new(0)
        @failures = []
        @published = []
        @env = {}
        @seconds = 0.0
      end

      # The call env the tool pipeline hands its subscribers is one mutable
      # hash per call, so the entry kept here at :before_tool carries the
      # result the tool answered with by the time anyone reads it.
      def subscribe(agent)
        agent
          .on(:before_tool) { |_env, call| @calls << call }
          .on(:after_llm) { |env| account(env[:metadata][:last_llm_usage]) }
          .on(:faraday_error) { |_env, error| @failures << describe(error) }
          .on(:open_router_server_error) { |_env, error| @failures << describe(error) }
          .on(:standard_error) { |_env, error| @failures << describe(error) }
          .on(:turn_end) { |env| @env = env }
      end

      def names = @calls.map { |call| call[:name] }

      def counts = names.tally

      def iterations = @env[:current_iteration] || 0

      def tokens = @usage[:total]

      def errors = @calls.count { |call| call[:result].to_s.start_with?("Error") }

      def reply
        if @env[:messages].nil?
          ""
        else
          @env.extend(Brute::Env).reply&.content.to_s
        end
      end

      # A call the turn made, matched on name and on whatever arguments the
      # case cares about -- `===`, so a case says `"query" => /fed/i` as
      # readily as `"count" => 3`.
      def called?(name, arguments = {})
        @calls.any? { |call|
          call[:name] == name.to_s &&
            arguments.all? { |key, wanted| wanted === call[:arguments][key.to_s] }
        }
      end

      def before?(first, second)
        at = names.index(first.to_s)
        then_at = names.index(second.to_s)

        if at.nil?
          false
        else
          then_at.nil? || at < then_at
        end
      end

      private

        def describe(error) = "#{error.class}: #{error.message}"

        # Providers report what they report: a total that was never sent is
        # not derived here, it is added up from the parts that were.
        def account(usage)
          if usage
            @usage[:input] += usage.input.to_i
            @usage[:output] += usage.output.to_i
            @usage[:total] += usage.total || usage.input.to_i + usage.output.to_i
          end
        end
    end
  end
end

__END__

describe "brute/eval/transcript" do
  it "records what the turn called, what it answered, and what it cost" do
    search = Brute::Turn::ToolPipeline.new(name: "search", description: "search the web") do
      run ->(env) { env[:result] = "the bank held rates at 4.25%" }
    end

    replies = [
      Brute::Message.new(
        role: :assistant,
        content: "",
        tool_calls: [{ id: "1", name: "search", arguments: { "query" => "bank rate" } }]
      ),
      Brute::Message.new(role: :assistant, content: "It held at 4.25%."),
    ]

    agent = Brute.agent
      .use(Brute::Middleware::Loop::ToolResult)
      .use(Brute::Middleware::DefaultToolPipeline, tools: [search])
      .run(->(env) { env[:messages] << replies.shift })

    transcript = Brute::Eval::Transcript.new
    transcript.subscribe(agent)
    agent.start("what did the bank do?")

    transcript.names.should == ["search"]
    transcript.counts.should == { "search" => 1 }
    transcript.called?("search", "query" => /bank/i).should.be.true
    transcript.called?("search", "query" => /ecb/i).should.be.false
    transcript.called?("fetch").should.be.false
    transcript.before?("search", "fetch").should.be.true
    transcript.before?("fetch", "search").should.be.false
    transcript.reply.should == "It held at 4.25%."
    transcript.iterations.should == 2
    transcript.errors.should == 0
    transcript.failures.should.be.empty

    failed = Brute::Eval::Transcript.new
    failed.reply.should == ""
    failed.tokens.should == 0
  end
end
