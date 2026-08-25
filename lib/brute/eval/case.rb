# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Eval
    # The budget a case allows itself. Lenient on purpose: an agent that took
    # one search too many is worth knowing about, but it is not the same
    # fault as an agent that answered wrongly.
    Budget = Data.define(:iterations, :tool_calls, :tokens, :seconds) do
      def initialize(iterations: 10, tool_calls: 8, tokens: 100_000, seconds: 180)
        super
      end
    end

    # One evaluation case: what the agent is told, the world it is told it
    # in, and what must be true of the turn afterwards.
    #
    #   Brute::Eval::Case.new(
    #     "searches for what it cannot know",
    #     said:     "what did the Bank of England do yesterday?",
    #     stubs:    { "search" => RATE_DECISION },
    #     calls:    { "search" => { "query" => /bank|rate/i } },
    #     mentions: %w[4.25],
    #     budget:   Brute::Eval::Budget.new(tool_calls: 2),
    #   )
    #
    # The expectations are deliberately about what the turn DID, not about
    # prose: a call that was made, a call that was not, the order two calls
    # came in, a word the answer has to contain, a budget it has to stay
    # inside. What none of those can say goes in the block, which is handed
    # the transcript.
    #
    # `said` reaches the agent through the world -- an inbox on disk, a queue,
    # whatever that deployment's world does with it -- unless `via: :start`
    # hands it straight to the turn. `files` and `conversation` are the
    # world's to lay out and mean nothing to a world that keeps no state.
    class Case
      # A system prompt that tells an agent to say plainly when it found
      # nothing is graded on this. It is a crude reading -- a judge would do
      # it properly -- and it is English, so a deployment whose agents answer
      # in another language passes its own `absence:`.
      ABSENCE = /\b(no|not|none|nothing|cannot|can't|couldn't|didn't|don't|doesn't|isn't|aren't|unable|unfortunately|missing|without)\b/i

      Verdict = Data.define(:failures) do
        def passed? = failures.empty?
      end

      attr_reader :name, :said, :via, :files, :conversation, :stubs, :budget, :runs

      def initialize(
        name,
        said: nil,
        via: :world,
        files: {},
        conversation: [],
        stubs: {},
        calls: {},
        never: [],
        order: [],
        mentions: [],
        absent: false,
        absence: ABSENCE,
        silent: false,
        budget: Budget.new,
        runs: 1,
        &check
      )
        @name = name
        @said = said
        @via = via
        @files = files
        @conversation = conversation
        @stubs = stubs
        @calls = calls
        @never = never
        @order = order
        @mentions = mentions
        @absent = absent
        @absence = absence
        @silent = silent
        @budget = budget
        @runs = runs
        @check = check
      end

      def verdict(transcript)
        Verdict.new(
          [
            answered(transcript),
            called(transcript),
            ordered(transcript),
            said_it(transcript),
            afforded(transcript),
            checked(transcript),
          ].flatten.compact.uniq
        )
      end

      private

        def answered(transcript)
          [].tap do |failures|
            if transcript.error
              failures << "raised #{transcript.error.class}: #{transcript.error.message}"
            end

            transcript.failures.each { |failure| failures << "the model call failed -- #{failure}" }

            if transcript.reply.empty? && !@silent
              failures << "said nothing"
            end

            if !transcript.reply.empty? && @silent
              failures << "answered when it had nothing to answer"
            end
          end
        end

        def called(transcript)
          [].tap do |failures|
            @calls.each do |name, arguments|
              unless transcript.called?(name, arguments || {})
                failures << "never called #{name}#{about(arguments)}"
              end
            end

            @never.each do |name|
              if transcript.called?(name)
                failures << "called #{name}"
              end
            end
          end
        end

        def ordered(transcript)
          @order.each_cons(2).filter_map do |first, second|
            unless transcript.before?(first, second)
              if transcript.called?(first)
                "called #{second} before #{first}"
              else
                "never called #{first}"
              end
            end
          end
        end

        def said_it(transcript)
          @mentions.filter_map { |word|
            unless transcript.reply.downcase.include?(word.downcase)
              "never said #{word.inspect}"
            end
          }.tap do |failures|
            if @absent && !@absence.match?(transcript.reply)
              failures << "did not say it had nothing"
            end
          end
        end

        def afforded(transcript)
          [
            over("iterations", transcript.iterations, @budget.iterations),
            over("tool calls", transcript.calls.length, @budget.tool_calls),
            over("tokens", transcript.tokens, @budget.tokens),
            over("seconds", transcript.seconds.round, @budget.seconds),
          ]
        end

        def checked(transcript)
          if @check && !@check.call(transcript)
            "failed the case's own check"
          end
        end

        def over(what, spent, allowed)
          if spent > allowed
            "spent #{spent} #{what}, budget #{allowed}"
          end
        end

        def about(arguments)
          if arguments.nil? || arguments.empty?
            ""
          else
            " with #{arguments.inspect}"
          end
        end
    end
  end
end

__END__

describe "brute/eval/case" do
  it "grades a turn on what it did, and says what was wrong when it did not" do
    turn = Struct.new(:names, :reply, :iterations, :tokens, :seconds, :error, :calls) do
      def failures = []
      def called?(name, arguments = {}) = names.include?(name.to_s) && arguments.empty?
      def before?(first, second) = names.index(first).to_i < (names.index(second) || 99)
    end

    searched = turn.new(%w[search], "It held at 4.25%.", 2, 900, 3, nil, [1])

    good = Brute::Eval::Case.new(
      "searches for what it cannot know",
      said: "what did the bank do?",
      calls: { "search" => {} },
      mentions: %w[4.25],
      never: %w[create_event]
    )
    good.verdict(searched).passed?.should.be.true
    good.via.should == :world
    good.runs.should == 1

    fussy = Brute::Eval::Case.new(
      "does not search for what it knows",
      said: "how many minutes in an hour?",
      via: :start,
      never: %w[search],
      mentions: %w[sixty],
      order: %w[read search],
      budget: Brute::Eval::Budget.new(iterations: 1)
    ) { |graded| graded.tokens < 100 }

    fussy.via.should == :start
    fussy.verdict(searched).failures.should == [
      "called search",
      "never called read",
      'never said "sixty"',
      "spent 2 iterations, budget 1",
      "failed the case's own check",
    ]

    quiet = turn.new([], "", 1, 10, 1, nil, [])
    Brute::Eval::Case.new("answers", said: "hi").verdict(quiet).failures.should == ["said nothing"]
    Brute::Eval::Case.new("holds its tongue", silent: true).verdict(quiet).passed?.should.be.true

    broken = turn.new([], "", 1, 10, 1, ArgumentError.new("no such agent file"), [])
    Brute::Eval::Case.new("loads", said: "hi").verdict(broken).failures.first.should ==
      "raised ArgumentError: no such agent file"

    nothing_found = turn.new([], "The search turned up nothing about that.", 1, 10, 1, nil, [])
    Brute::Eval::Case.new("admits it", said: "when does it ship?", absent: true)
      .verdict(nothing_found).passed?.should.be.true
    Brute::Eval::Case.new("admits it in French", said: "?", absent: true, absence: /rien/i)
      .verdict(nothing_found).failures.should == ["did not say it had nothing"]
  end
end
