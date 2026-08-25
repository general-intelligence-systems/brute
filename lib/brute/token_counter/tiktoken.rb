# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module TokenCounter
    # Tokens from OpenAI's byte-pair encoder, through the tiktoken_ruby gem.
    #
    #   gem "tiktoken_ruby"
    #   use Brute::Middleware::DefaultCompactionPipeline,
    #     window:        200_000,
    #     token_counter: Brute::TokenCounter::Tiktoken.new
    #
    # Brute depends on no LLM library, and this is no exception: the gem is
    # required the first time the counter is asked for a number, so an agent
    # that never installs it never pays for it and never hears about it.
    #
    # It is exact about the text and still approximate about the request --
    # `per_message` stands in for the chat-template framing, which is the
    # provider's and not in any encoder.
    class Tiktoken
      ENCODING = "o200k_base"

      def initialize(encoding: ENCODING, per_message: 4, encoder: nil)
        @encoding = encoding
        @per_message = per_message
        @encoder = encoder
      end

      # Load the encoder, downloading its vocabulary if it is not cached yet.
      def warm_up
        @encoder ||= load_encoder
      end

      def count(messages, tools: nil)
        warm_up
        text = Rendering.conversation(messages) + Rendering.tools(tools)

        @encoder.encode(text).length + (Array(messages).length * @per_message)
      end

      private

        def load_encoder
          begin
            require "tiktoken_ruby"
          rescue LoadError
            raise LoadError, "#{self.class} needs the tiktoken_ruby gem: add `gem \"tiktoken_ruby\"` to your Gemfile"
          end

          ::Tiktoken.get_encoding(@encoding)
        end
    end
  end
end

__END__

describe "brute/token_counter/tiktoken" do
  it "encodes the same rendering the approximate counter measures, and says what to install when it cannot" do
    encoded = []
    encoder = Object.new
    encoder.define_singleton_method(:encode) { |text| encoded << text; text.split(/\b/) }

    log = Brute.log
    log.user("what changed?")

    counter = Brute::TokenCounter::Tiktoken.new(encoder: encoder, per_message: 4)
    counter.count(log).should == encoder.encode("user: what changed?").length + 4
    encoded.last.should == "user: what changed?"

    # The vocabulary is loaded once, on the first count rather than at boot.
    counter.warm_up.should.equal? encoder

    missing = Brute::TokenCounter::Tiktoken.new(encoding: "nothing-real")
    missing.define_singleton_method(:require) { |_name| raise LoadError }
    lambda { missing.count(log) }.should.raise(LoadError).message.should.include "tiktoken_ruby"
  end
end
