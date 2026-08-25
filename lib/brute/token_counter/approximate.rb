# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module TokenCounter
    # Tokens from text length, at a flat ratio of characters to tokens.
    #
    # Four characters to the token is the usual approximation. It needs no
    # dependency and it is close enough to decide what to give up; put a
    # Tiktoken counter on env[:token_counter] when the difference matters.
    #
    # `per_message` is what the rendering cannot see: every message is wrapped
    # in the provider's own chat template on the way out, and that framing
    # costs a few tokens each whatever the message says.
    class Approximate
      def initialize(chars_per_token: 4.0, per_message: 4)
        unless chars_per_token.positive?
          raise ArgumentError, "chars_per_token must be greater than 0, got #{chars_per_token}"
        end

        @chars_per_token = chars_per_token
        @per_message = per_message
      end

      def count(messages, tools: nil)
        text = Rendering.conversation(messages) + Rendering.tools(tools)

        (text.length / @chars_per_token).to_i + (Array(messages).length * @per_message)
      end
    end
  end
end

__END__

describe "brute/token_counter/approximate" do
  it "divides the rendered text by the ratio, and charges for the envelope each message rides in" do
    log = Brute.log
    log.user("a" * 400)

    # "user: " + 400 characters, four to the token, plus the envelope.
    Brute::TokenCounter::Approximate.new.count(log).should == 105

    # The ratio and the envelope are both settings, not truths.
    Brute::TokenCounter::Approximate.new(chars_per_token: 2.0).count(log).should == 207
    Brute::TokenCounter::Approximate.new(per_message: 0).count(log).should == 101

    Brute::TokenCounter::Approximate.new.count([]).should == 0

    lambda { Brute::TokenCounter::Approximate.new(chars_per_token: 0) }.should.raise(ArgumentError)
  end
end
