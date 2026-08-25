# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/eval/transcript"
require "brute/eval/world"

module Brute
  module Eval
    # Runs the cases against one agent and reports what happened.
    #
    #   Brute::Eval::Suite.new(agent: "agent.ru", cases: CASES).run
    #   Brute::Eval::Suite.new(agent: -> { build_agent }, world: Room.new, cases: CASES).run
    #
    # The agent is built fresh for every attempt -- from its .ru file, or
    # from a block that answers a new pipeline -- so nothing carries from one
    # case to the next but the world, which is laid out again first. A case
    # with `runs:` above one is run that many times and passes only if every
    # run did: the model is not deterministic, and a case that passes two
    # times in three is a case that fails.
    #
    # #run answers a process exit status, so an eval script ends `exit(...)`.
    class Suite
      Result = Data.define(:kase, :run, :transcript, :verdict)

      def initialize(agent:, cases:, world: World.new, out: $stdout)
        @agent = agent
        @cases = cases
        @world = world
        @out = out
      end

      def run
        results = @cases.flat_map { |kase| attempts(kase) }
        summarise(results)

        if results.all? { |result| result.verdict.passed? }
          0
        else
          1
        end
      end

      private

        def attempts(kase)
          (1..kase.runs).map do |run|
            attempt(kase, run).tap { |result| report(result) }
          end
        end

        def attempt(kase, run)
          input = @world.prepare(kase)
          transcript = Transcript.new
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            agent = build
            transcript.subscribe(agent)
            @world.stub(agent, kase.stubs)
            agent.start(input)
          rescue StandardError => e
            transcript.error = e
          end

          transcript.seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          transcript.published = @world.published.dup

          Result.new(
            kase: kase,
            run: run,
            transcript: transcript,
            verdict: kase.verdict(transcript)
          )
        end

        def build
          if @agent.respond_to?(:call)
            @agent.call
          else
            Brute.load_agent(@agent)
          end
        end

        def report(result)
          transcript = result.transcript
          budget = result.kase.budget

          @out.puts
          @out.puts "[#{outcome(result)}] #{result.kase.name}#{run_of(result)}"
          @out.puts "  tools: #{transcript.counts}  errors: #{transcript.errors}"
          @out.puts(
            "  spent: #{transcript.iterations}/#{budget.iterations} iterations, " \
            "#{transcript.calls.length}/#{budget.tool_calls} calls, " \
            "#{transcript.tokens}/#{budget.tokens} tokens, " \
            "#{transcript.seconds.round(1)}s"
          )
          result.verdict.failures.each { |failure| @out.puts "  - #{failure}" }
          @out.puts "  said:"
          transcript.reply.each_line { |line| @out.puts "    #{line.chomp}" }
        end

        def summarise(results)
          cases = results.group_by { |result| result.kase }
          passed = cases.count { |_kase, attempts| attempts.all? { |result| result.verdict.passed? } }

          @out.puts
          @out.puts "=== #{passed}/#{cases.length} cases passed ==="
          @out.puts "tokens: #{results.sum { |result| result.transcript.tokens }}"
          @out.puts "time: #{results.sum { |result| result.transcript.seconds }.round(1)}s"
        end

        def outcome(result)
          if result.verdict.passed?
            "PASS"
          else
            "FAIL"
          end
        end

        def run_of(result)
          if result.kase.runs == 1
            ""
          else
            " (run #{result.run}/#{result.kase.runs})"
          end
        end
    end
  end
end

__END__

require "stringio"
require "tmpdir"

describe "brute/eval/suite" do
  it "runs every case against a freshly built agent and reports what happened" do
    out = StringIO.new

    suite = Brute::Eval::Suite.new(
      agent: -> { Brute.agent.run(->(env) { env[:messages].assistant("it held at 4.25%") }) },
      cases: [
        Brute::Eval::Case.new("answers", said: "what did the bank do?", mentions: %w[4.25]),
        Brute::Eval::Case.new("searches", said: "what did the bank do?", calls: { "search" => {} }),
      ],
      out: out
    )

    suite.run.should == 1
    out.string.should.include "[PASS] answers"
    out.string.should.include "[FAIL] searches"
    out.string.should.include "- never called search"
    out.string.should.include "=== 1/2 cases passed ==="

    Dir.mktmpdir do |dir|
      path = File.join(dir, "agent.ru")
      File.write(path, 'run ->(env) { env[:messages].assistant("from the ru file") }')

      loaded = Brute::Eval::Suite.new(
        agent: path,
        cases: [Brute::Eval::Case.new("loads a ru file", said: "hi", mentions: ["ru file"])],
        out: out
      )
      loaded.run.should == 0

      missing = Brute::Eval::Suite.new(
        agent: File.join(dir, "nowhere.ru"),
        cases: [Brute::Eval::Case.new("answers", said: "hi")],
        out: out
      )
      missing.run.should == 1
      out.string.should.include "raised ArgumentError"
    end
  end
end
