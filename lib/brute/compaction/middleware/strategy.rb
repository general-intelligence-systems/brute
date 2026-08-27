# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Compaction
    # Compaction strategies, as the layers of a Brute::Turn::CompactionPipeline.
    module Middleware
      # One strategy in the ladder.
      #
      # The stack order is the policy. A layer that got the conversation under
      # target never calls the next one, so the strategies that cost nothing
      # sit at the top and the one that spends a model call is only reached
      # when they could not get there.
      #
      # A subclass answers #strategy and #rewrite, and nothing else. The rules
      # every strategy has to keep are here: it is only asked while the
      # conversation is over target, and what it answers is only taken when it
      # actually made the conversation smaller -- otherwise the pipeline above
      # would write the same size back on every step, forever.
      #
      # The same class serves as a layer or as the terminal, which is what the
      # ladder is built out of: the strategies that cost nothing are `use`d,
      # and the one that spends a model call is `run`, reached only when they
      # could not get under target.
      #
      #   Brute::Turn::CompactionPipeline.new do
      #     use Brute::Compaction::Middleware::ToolResults
      #     use Brute::Compaction::Middleware::SlidingWindow
      #     run Brute::Compaction::Middleware::Summary.new(summarize: summarize)
      #   end
      #
      class Strategy < Brute::Middleware::Base
        def call(env)
          @env = env

          if Brute::Compaction.over_target?(env)
            apply(env)
          end

          # Under target now, so the rest of the ladder is not needed.
          if Brute::Compaction.over_target?(env)
            @app.call(env)
          end

          env
        end

        # The name this strategy compacts under, recorded on what it produces.
        def strategy = raise(NotImplementedError, "#{self.class} must answer #strategy")

        # Answer a smaller conversation, or nil to decline. Build a new list:
        # the one handed over belongs to the caller.
        def rewrite(_conversation, target:) = raise(NotImplementedError, "#{self.class} must answer #rewrite")

        private

          # Measured with whatever counter the turn decided on, so a strategy
          # weighs the conversation the same way the trigger did.
          def tokens(messages) = Brute::Compaction.counter(@env).count(messages)

          def apply(env)
            rewritten = rewrite(env[:conversation], target: env[:target])

            unless rewritten.nil?
              before = tokens(env[:conversation])
              after = tokens(rewritten)

              if after < before
                env[:conversation] = rewritten
                env[:applied] << { strategy: strategy, before: before, after: after }
              end
            end
          end
      end
    end
  end
end

__END__

describe "brute/compaction/middleware/strategy" do
  def said(content) = Brute::Message.new(role: :user, content: content)

  def strategy(name, &block)
    Class.new(Brute::Compaction::Middleware::Strategy) do
      define_method(:strategy) { name }
      define_method(:rewrite) { |conversation, target:| block.call(conversation, target) }
    end
  end

  it "asks a strategy only while over target, takes only what shrank, and stops the ladder there" do
    asked = []
    halves  = strategy("halves")  { |c, _t| asked << "halves"; c.first(c.length / 2) }
    nothing = strategy("nothing") { |c, _t| asked << "nothing"; c.dup }
    never   = strategy("never")   { |_c, _t| asked << "never"; nil }

    run = lambda do |layers, conversation, target|
      app = ->(env) { env }
      layers.reverse_each { |layer| app = layer.new(app) }
      env = { conversation: conversation, target: target, applied: [], events: [] }
      app.call(env)
      env
    end

    four = [said("a" * 4_000), said("b" * 4_000), said("c" * 4_000), said("d" * 4_000)]

    # Halving is enough, so nothing below it is reached -- which is what keeps
    # the strategy that costs money out of a turn the free ones could handle.
    env = run.call([halves, never], four, 3_000)
    env[:conversation].map { |m| m.content[0, 1] }.should == ["a", "b"]
    asked.should == ["halves"]
    env[:applied].should == [{ strategy: "halves", before: 4_022, after: 2_011 }]

    # A rewrite that saved nothing is refused and the ladder carries on past
    # it, so the strategy itself never has to check.
    asked.clear
    env = run.call([nothing, halves], four, 3_000)
    asked.should == ["nothing", "halves"]
    env[:applied].map { |a| a[:strategy] }.should == ["halves"]

    # Already under target: nothing is asked at all.
    asked.clear
    run.call([halves, never], four, 100_000)[:applied].should == []
    asked.should == []

    # A strategy that declines lets the next one try.
    asked.clear
    run.call([never, halves], four, 3_000)[:applied].map { |a| a[:strategy] }.should == ["halves"]

    # The base insists a subclass says what it is and what it does.
    bare = Class.new(Brute::Compaction::Middleware::Strategy).new(->(e) { e })
    should.raise(NotImplementedError) { bare.strategy }
    should.raise(NotImplementedError) { bare.rewrite([], target: 0) }
  end
end
