# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/usage_detection/usage"

module Brute
  module UsageDetection
    # langchainrb has no single usage object: each provider's response
    # subclass answers prompt_tokens / completion_tokens / total_tokens by
    # digging its own raw shape, and some answer none of them.
    module LangChain
      def self.detect(response)
        detected = Usage.new(
          input:  read(response, :prompt_tokens),
          output: read(response, :completion_tokens),
          total:  read(response, :total_tokens),
          raw:    response,
        )

        detected.empty? ? nil : detected
      end

      def self.read(response, name) = response.respond_to?(name) ? response.public_send(name) : nil
    end
  end
end

__END__

describe "brute/usage_detection/lang_chain" do
  LangChainResponse = Struct.new(:prompt_tokens, :completion_tokens, :total_tokens) unless defined?(LangChainResponse)

  it "reads the per-provider token methods and answers nil when the response has none" do
    usage = Brute::UsageDetection::LangChain.detect(LangChainResponse.new(10, 5, 15))
    usage.input.should == 10
    usage.output.should == 5
    usage.total.should == 15

    # A provider subclass that reports nothing.
    Brute::UsageDetection::LangChain.detect(LangChainResponse.new(nil, nil, nil)).should.be.nil
    Brute::UsageDetection::LangChain.detect(Object.new).should.be.nil
  end
end
