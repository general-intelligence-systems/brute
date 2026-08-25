# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # Giving up part of a conversation so the rest still fits.
  #
  # The strategies are middleware (Brute::Middleware::Compact) and they are
  # composed into a compactor by Brute::Turn::CompactionPipeline. What lives
  # here is what every one of them needs: the grouping in Transcript, the
  # counter that decides how big anything is, and the two questions the stack
  # is built around.
  #
  # A compaction env carries the conversation on `:conversation` rather than
  # `:messages`, because `:messages` is the prompt channel the terminal app
  # reads and answers on -- the same contract a completion has in any other
  # Brute pipeline.
  module Compaction
    # Whatever the turn decided to weigh with, remembered on the env so the
    # trigger and every strategy below it answer the same question the same
    # way. Brute::TokenCounter::Approximate when nobody said otherwise.
    def self.counter(env) = env[:token_counter] ||= TokenCounter.default

    def self.tokens(env, messages = env[:conversation]) = counter(env).count(messages)

    # Is the conversation still bigger than it is allowed to be?
    def self.over_target?(env) = tokens(env) > env[:target]
  end
end

__END__

describe "brute/compaction" do
  it "measures a conversation, and answers whether it is still too big" do
    env = { conversation: [Brute::Message.new(role: :user, content: "a" * 400)], target: 50 }

    # Four characters to the token, plus a little for the envelope.
    Brute::Compaction.tokens(env).should == 105
    Brute::Compaction.over_target?(env).should.be.true

    env[:target] = 5_000
    Brute::Compaction.over_target?(env).should.be.false

    # The counter is remembered on the env, so every layer weighs the
    # conversation the same way the trigger did...
    Brute::Compaction.counter(env).should.be.kind_of Brute::TokenCounter::Approximate
    env[:token_counter].equal?(Brute::Compaction.counter(env)).should.be.true

    # ...and one put there beforehand is the one that gets used.
    counted = []
    given = { conversation: [], target: 1, token_counter: Object.new }
    given[:token_counter].define_singleton_method(:count) { |messages, tools: nil| counted << messages; 7 }
    Brute::Compaction.tokens(given).should == 7
    counted.length.should == 1
  end
end
