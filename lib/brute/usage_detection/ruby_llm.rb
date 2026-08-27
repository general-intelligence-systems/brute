# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/usage_detection/usage"

module Brute
  module UsageDetection
    # ruby_llm hangs usage off the *message*, not the response: a Tokens
    # object with input/output/cache_read/cache_write/thinking, plus the
    # provider's own reported_cost when it gives one.
    module RubyLLM
      def self.detect(message)
        if message.respond_to?(:tokens)
          tokens = message.tokens
          if tokens.nil?
            nil
          else
            Usage.new(
              input:       read(tokens, :input),
              output:      read(tokens, :output),
              reasoning:   read(tokens, :thinking),
              cache_read:  read(tokens, :cache_read),
              cache_write: read(tokens, :cache_write),
              cost:        read(tokens, :reported_cost),
              raw:         tokens,
            )
          end
        else
          nil
        end
      end

      def self.read(tokens, name) = tokens.respond_to?(name) ? tokens.public_send(name) : nil
    end
  end
end

__END__

describe "brute/usage_detection/ruby_llm" do
  FakeTokens = Struct.new(:input, :output, :cache_read, :cache_write, :thinking, :reported_cost) unless defined?(FakeTokens)
  FakeMessage = Struct.new(:tokens) unless defined?(FakeMessage)

  it "reads Tokens off the message, maps thinking to reasoning, and answers nil for no usage" do
    usage = Brute::UsageDetection::RubyLLM.detect(FakeMessage.new(FakeTokens.new(10, 5, 2, 1, 4, 0.002)))

    usage.input.should == 10
    usage.output.should == 5
    usage.total.should.be.nil # ruby_llm reports parts, not a total
    usage.reasoning.should == 4
    usage.cache_read.should == 2
    usage.cache_write.should == 1
    usage.cost.should == 0.002

    Brute::UsageDetection::RubyLLM.detect(FakeMessage.new(nil)).should.be.nil
    Brute::UsageDetection::RubyLLM.detect(Object.new).should.be.nil
  end
end
