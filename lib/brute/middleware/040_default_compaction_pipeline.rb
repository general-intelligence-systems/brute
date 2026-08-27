# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Compacts the conversation once it fills too much of the model's window.
    #
    # This layer owns the *when*: before each call it estimates the size of the
    # conversation, and once it reaches `compact_at` of the window it asks a
    # compactor to bring it down to `compact_to`. What is given up, and in what
    # order, is the compactor's business.
    #
    #   use Brute::Middleware::Loop::ToolResult
    #   use Brute::Middleware::DefaultCompactionPipeline,
    #     window:     200_000,
    #     summariser: Brute::Completion::OpenRouter.new(config: { access_token: key })
    #   use Brute::Middleware::DefaultToolPipeline, tools: tools
    #
    # The compactor it builds is the usual ladder, cheapest first:
    #
    #   use Brute::Compaction::Middleware::ToolResults     rewrite older tool output
    #   use Brute::Compaction::Middleware::SlidingWindow   drop the oldest turns, then steps
    #   run Brute::Compaction::Summarize                   summarise what is left, until it fits
    #
    # Pass `compactor:` to say something else. A Brute::Turn::CompactionPipeline
    # is the usual thing to pass, but anything answering
    # `#compact(messages, target:)` will do. Passing no summariser leaves the
    # terminal doing nothing, which is how an agent says it would rather live
    # with a full context than pay to shrink it.
    #
    # It belongs inside the tool loop rather than around it, so it runs before
    # every call rather than once a turn -- a long run of tool results can fill
    # the window without the turn ever ending.
    #
    # Sizing anchors on what the provider itself counted for the last call and
    # measures locally only what has been appended since, so the estimate is
    # exact for the bulk of the conversation and approximate only for its tail.
    #
    # Tool schemas ride in every request and are part of what fills a window,
    # so they are counted too -- against the trigger when nothing has been
    # reported yet, and off the target the compactor is given, because what
    # the schemas occupy is not room the conversation may have. This layer
    # sits above the tool pipeline, so on the very first call of a turn
    # env[:tools] is not set yet: pass `tools:` to have them counted then.
    #
    # Compaction is lossy, and this layer keeps no record of what it gave up:
    # it rewrites env[:messages] and says so with :compact_end. An application
    # that keeps a transcript preserves it from there.
    #
    #   agent.on(:compact_end) { |env, payload| archive(env, payload) }
    #
    class DefaultCompactionPipeline < Brute::Middleware::Base
      def initialize(app, window:, summariser: nil, compactor: nil, keep_steps: 2,
                     compact_at: 0.7, compact_to: 0.4, token_counter: nil, tools: nil)
        unless compact_to.positive? && compact_to < compact_at && compact_at <= 1
          raise ArgumentError, "expected 0 < compact_to < compact_at <= 1, got #{compact_to} and #{compact_at}"
        end

        @app = app
        @compactor = compactor || self.class.compactor(summariser: summariser, keep_steps: keep_steps)
        @window = window
        @compact_at = compact_at
        @compact_to = compact_to
        @token_counter = token_counter || Brute::TokenCounter.default
        @tools = tools
      end

      def call(env)
        env[:compactor] = @compactor
        compact(env)
        @app.call(env)
        env
      end

      # The ladder this layer wires when it is not given one.
      def self.compactor(summariser: nil, keep_steps: 2)
        terminal = Declines.new

        unless summariser.nil?
          terminal = Brute::Compaction::Summarize.new(summariser, keep_steps: keep_steps)
        end

        Brute::Turn::CompactionPipeline.new do
          use Brute::Compaction::Middleware::ToolResults, keep_steps: 1
          use Brute::Compaction::Middleware::SlidingWindow, keep_steps: keep_steps

          run terminal
        end
      end

      # The floor of a pipeline given nothing to summarise with: what the free
      # layers managed is what the turn gets.
      class Declines
        def call(env) = env
      end

      private

        def compact(env)
          context = estimate(env)

          env.emit_trace do |env|
            if context >= @window * @compact_at
              env.emit(COMPACT_START_EVENT, { context: context })

              before = @token_counter.count(env[:messages])
              compacted = attempt(env, target(env))

              unless compacted.nil?
                env[:messages].replace(compacted)
                # The reported total describes a conversation that no longer
                # exists, so the next estimate must not build on it. The call
                # below refreshes it; one that fails leaves the estimate to be
                # counted from scratch instead of anchored to a fiction.
                env[:metadata]&.delete(:last_llm_usage)
                env.emit(
                  COMPACT_END_EVENT,
                  { context: context, before: before, after: @token_counter.count(compacted) },
                )
              end
            end
          end
        end

        # What the conversation alone may occupy: the target, less whatever
        # the schemas are already taking out of it. A window too small to
        # hold its own tool schemas is a configuration a compactor cannot
        # fix, so the floor is 1 rather than a negative target.
        def target(env)
          [(@window * @compact_to).to_i - schemas(env), 1].max
        end

        def schemas(env)
          tools = @tools || env[:tools]

          if tools.nil?
            0
          else
            @token_counter.count([], tools: tools)
          end
        end

        # A compactor that raises is a compactor that declined. Compaction is
        # an optimisation, and an agent that cannot shrink its context should
        # carry on with the context it has rather than die of it.
        def attempt(env, target)
          compacted = nil

          env.emit(COMPACT_DURATION_EVENT, env[:compactor]) do
            compacted = env[:compactor].compact(
              env[:messages],
              target:        target,
              token_counter: @token_counter,
            )
          end

          compacted
        rescue => error
          env.emit(COMPACT_FAILURE_EVENT, error)
          nil
        end

        # What the provider counted for the last call already covers the
        # system prompt, the tool schemas and the chat-template overhead, so
        # only what has landed since it answered needs counting here.
        def estimate(env)
          Brute::TokenCounter.estimate(env, counter: @token_counter, tools: @tools || env[:tools])
        end
    end
  end
end

__END__

describe "brute/middleware/040_default_compaction_pipeline" do
  def conversation
    Brute.log.tap do |log|
      log.user("ask" + ("x" * 1_000))
      log.assistant("answer" + ("y" * 1_000))
    end
  end

  def usage(total) = { last_llm_usage: Brute::UsageDetection::Usage.new(total: total) }

  def history(turns: 4, size: 6_000)
    Brute.log.tap do |log|
      log.system("instructions")
      turns.times do |n|
        log.user("question #{n}")
        log << Brute::Message.new(role: :assistant, content: n.to_s * size)
      end
      log.user("the current task")
      log << Brute::Message.new(role: :assistant, content: "z" * size)
    end
  end

  def traced(env, hooks = Brute::Hooks::Registry.new)
    Brute::Hooks::Trace.new(env, hooks: hooks)
  end

  def compactor(&block)
    Object.new.tap do |double|
      double.define_singleton_method(:compact) { |messages, target:, **| block.call(messages, target) }
    end
  end

  it "compacts only once the window fills, and says what the turn gave up" do
    asked = []
    events = []
    shrinks  = compactor { |messages, target| asked << target; messages.first(1) }
    declines = compactor { |_messages, target| asked << target; nil }
    raises   = compactor { |_messages, _target| raise IOError, "the summariser is down" }

    hooks = Brute::Hooks::Registry.new
    %i[compact_end compact_failure].each { |event| hooks.on(event) { |_env, *extras| events << [event, *extras.first(1)] } }
    hooks.on(:compact_duration) { |_env, *| events << [:compact_duration] }

    layer = lambda do |compactor|
      Brute::Middleware::DefaultCompactionPipeline.new(
        ->(env) { env },
        compactor: compactor,
        window: 1_000,
        compact_at: 0.7,
        compact_to: 0.4,
      )
    end

    env = traced({ messages: conversation, metadata: usage(900) }, hooks)
    layer.call(shrinks).call(env)

    asked.should == [400]
    env[:messages].map(&:role).should == [:user]
    env[:compactor].equal?(shrinks).should.be.true
    events.select { |e, _| e == :compact_end }.should == [[:compact_end, { context: 900, before: 514, after: 256 }]]
    # The attempt is timed, so the compactor that spends a model call is visible.
    events.select { |e, _| e == :compact_duration }.length.should == 1

    # Sizing anchors on what the provider counted: under compact_at nothing is
    # asked and nothing is said.
    asked.clear
    events.clear
    layer.call(shrinks).call(traced({ messages: conversation, metadata: usage(600) }, hooks))
    asked.should == []
    events.should == []

    # ...but what landed since it answered is counted on top of it, and that
    # is what tips this one over.
    tail = conversation.tap { |log| log.tool("z" * 400, tool_call_id: "tc1") }
    layer.call(declines).call(traced({ messages: tail, metadata: usage(600) }, hooks))
    asked.should == [400]

    # With nothing reported at all, the whole conversation is counted here.
    asked.clear
    layer.call(declines).call(traced({ messages: conversation }, hooks))
    asked.should == []

    # A compactor that raises is a compactor that declined: reported, not
    # fatal. An agent that cannot shrink its context carries on with it.
    events.clear
    failing = traced({ messages: conversation, metadata: usage(900) }, hooks)
    should.not.raise(IOError) { layer.call(raises).call(failing) }
    failing[:messages].length.should == 2
    events.select { |e, _| e == :compact_failure }.map { |_, error| error.message }
      .should == ["the summariser is down"]

    # A target at or above the trigger would compact on every single step.
    should.raise(ArgumentError) do
      Brute::Middleware::DefaultCompactionPipeline.new(->(e) { e }, compactor: shrinks, window: 10,
                                                             compact_at: 0.4, compact_to: 0.7)
    end
  end

  it "wires the usual ladder, cheapest first, and only pays when the free layers cannot" do
    rounds = 0
    summariser = lambda do |env|
      rounds += 1
      env[:messages] << Brute::Message.new(role: :assistant, content: "what happened")
    end

    ladder = Brute::Middleware::DefaultCompactionPipeline.compactor(summariser: summariser, keep_steps: 1)
    ladder.should.be.kind_of Brute::Turn::CompactionPipeline

    messages = history
    before = Brute::Compaction::Transcript.tokens(messages)
    out = ladder.compact(messages, target: 1_500)

    Brute::Compaction::Transcript.tokens(out).should.be < before

    # Given no summariser the terminal declines, and the free layers are all
    # the agent gets -- a policy said out loud rather than configured.
    free = Brute::Middleware::DefaultCompactionPipeline.compactor(summariser: nil, keep_steps: 1)
    free.compact(history, target: 1_500).should.not.be.nil

    # One layer, so it still owns the *when* as well as the what.
    layer = Brute::Middleware::DefaultCompactionPipeline.new(->(e) { e }, window: 1_000, summariser: summariser)
    env = traced({ messages: history, metadata: {} })
    layer.call(env)
    env[:messages].length.should.be < 11
  end

  it "counts the schemas it will send, and stops anchoring on a conversation that is gone" do
    asked = []
    shrinks = compactor { |messages, target| asked << target; messages.first(1) }

    tool = Brute::Turn::ToolPipeline.new(name: "search", description: "search the web. " * 40) do
      run ->(env) { env[:result] = "" }
    end
    schemas = Brute::TokenCounter.default.count([], tools: [tool])

    layer = lambda do |**options|
      Brute::Middleware::DefaultCompactionPipeline.new(
        ->(env) { env },
        compactor: shrinks,
        window: 1_000,
        **options,
      ).tap { |it| it.define_singleton_method(:emit) { |_event, _env, *, &work| work&.call } }
    end

    # 650 tokens of conversation, nothing reported yet: under the 700 the
    # window triggers at, so on its own it is left alone.
    said = -> { Brute.log.tap { |log| log.user("x" * 2_578) } }
    Brute::TokenCounter.default.count(said.call).should == 650

    layer.call.call(traced({ messages: said.call, metadata: {} }))
    asked.should == []

    # The same conversation ships with tool schemas in every request, and
    # counting what they occupy is what tips it over. What is left of the
    # target after them is what the compactor is asked for -- the schemas are
    # not room the conversation may have.
    layer.call(tools: [tool]).call(traced({ messages: said.call, metadata: {} }))
    asked.should == [400 - schemas]

    # Reported usage already covers the schemas, so the warm path must not
    # count them again -- 600 reported and nothing said since is 600, tools
    # or no tools.
    asked.clear
    layer.call(tools: [tool]).call(traced({ messages: conversation, metadata: usage(600) }))
    asked.should == []

    # What the provider counted describes the conversation as it was. Once
    # compaction has given part of it up that number is a fiction, so it goes
    # -- the next estimate counts from scratch rather than building on it.
    compacted = traced({ messages: conversation, metadata: usage(900) })
    layer.call.call(compacted)
    compacted[:messages].length.should == 1
    compacted[:metadata].key?(:last_llm_usage).should.be.false

    # Nothing given up, nothing invalidated.
    kept = traced({ messages: conversation, metadata: usage(900) })
    layer.call(compactor: compactor { |_messages, _target| nil }).call(kept)
    kept[:metadata].key?(:last_llm_usage).should.be.true
  end
end
