# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/turn/pipeline"

module Brute
  module Turn
    # A compactor built out of middleware.
    #
    # Like ToolPipeline it *composes* a Pipeline rather than inheriting: the
    # definition block is instance_eval'd into the internal Pipeline, so `use`
    # / `run` inside it are the builder's methods.
    #
    # The stack order is the policy. A layer that got the conversation under
    # target does not call the next one, so the strategies that cost nothing
    # sit at the top and the terminal app -- the summariser, the only thing
    # here that spends money -- is reached only when they could not get there.
    # That is `run` meaning what it means everywhere else in Brute: the model
    # call, at the bottom, with the layers deciding what reaches it.
    #
    #   Brute::Turn::CompactionPipeline.new do
    #     use Brute::Compaction::Middleware::ToolResults,   keep_steps: 1
    #     use Brute::Compaction::Middleware::SlidingWindow, keep_steps: 2
    #
    #     run Brute::Compaction::Summarize.new(
    #       Brute::Completion::OpenRouter.new(config: { access_token: key }),
    #     )
    #   end
    #
    # A pipeline that must never spend a call is the first two layers and
    # `run ->(env) { env }` -- a policy said out loud rather than configured.
    #
    # The conversation being compacted rides on `env[:conversation]`, leaving
    # `env[:messages]` to mean what it means to every other terminal app in
    # Brute: the prompt going down, the reply coming back.
    #
    # It answers #compact, so what comes out drops into
    # Brute::Middleware::DefaultCompactionPipeline as that turn's compactor.
    class CompactionPipeline
      def initialize(&block)
        @pipeline = Pipeline.new
        if block
          @pipeline.instance_eval(&block)
        end
      end

      # Answer a smaller conversation, or nil when nothing was given up.
      def compact(messages, target:, token_counter: nil)
        env = {
          conversation:  messages,
          target:        target,
          token_counter: token_counter,
          applied:       [],
          messages:      Brute.log,
          metadata:      {},
        }
        @pipeline.call(env)

        unless env[:applied].empty?
          env[:conversation]
        end
      end
    end
  end
end

__END__

describe "brute/turn/compaction_pipeline" do
  def said(content) = Brute::Message.new(role: :user, content: content)

  def layer(name, &block)
    Class.new(Brute::Compaction::Middleware::Strategy) do
      define_method(:strategy) { name }
      define_method(:rewrite) { |conversation, target:| block.call(conversation, target) }
    end
  end

  it "composes strategies into one compactor, and only reaches run when they could not" do
    reached = []
    halves = layer("halves") { |c, _t| reached << "halves"; c.first(c.length / 2) }
    never  = layer("never")  { |_c, _t| reached << "never"; nil }
    # A terminal belongs to one pipeline: the builder binds an emit onto it
    # and refuses to bind a second, so each pipeline gets its own.
    terminal = lambda do
      Object.new.tap { |it| it.define_singleton_method(:call) { |env| reached << "run"; env } }
    end

    four = [said("a" * 4_000), said("b" * 4_000), said("c" * 4_000), said("d" * 4_000)]

    # Halving is enough, so the terminal -- the one that costs money -- is
    # never reached. The stack order is the policy.
    pipeline = Brute::Turn::CompactionPipeline.new do
      use halves
      run terminal.call
    end
    pipeline.compact(four, target: 3_000).map { |m| m.content[0, 1] }.should == ["a", "b"]
    reached.should == ["halves"]

    # A strategy that declines lets the turn fall through to it.
    reached.clear
    Brute::Turn::CompactionPipeline.new do
      use never
      run terminal.call
    end.compact(four, target: 3_000).should.be.nil
    reached.should == ["never", "run"]

    # Nothing given up at all is nil, not the conversation it was handed --
    # the caller applies whatever else comes back.
    reached.clear
    pipeline.compact(four, target: 500_000).should.be.nil
    reached.should == []

    # The conversation rides on :conversation, leaving :messages to mean what
    # it means to every other terminal app -- the prompt down, the reply back.
    seen = nil
    Brute::Turn::CompactionPipeline.new do
      run ->(env) { seen = [env[:conversation].length, env[:messages], env[:target]] }
    end.compact(four, target: 10)
    seen.should == [4, [], 10]
  end
end
