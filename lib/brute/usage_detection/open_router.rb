# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/usage_detection/usage"

module Brute
  module UsageDetection
    # OpenRouter reports usage as the provider's raw hash on the response,
    # in OpenAI's wire shape. Reasoning tokens, when the model reports them,
    # arrive nested under completion_tokens_details.
    module OpenRouter
      def self.detect(response)
        return nil unless response.respond_to?(:usage)

        usage = response.usage
        return nil if usage.nil?

        usage = usage.to_h
        details = (usage["completion_tokens_details"] || usage[:completion_tokens_details] || {}).to_h

        Usage.new(
          input:     field(usage, "prompt_tokens"),
          output:    field(usage, "completion_tokens"),
          total:     field(usage, "total_tokens"),
          reasoning: field(details, "reasoning_tokens"),
          cache_read: field(usage, "cached_tokens"),
          cost:      field(usage, "cost"),
          raw:       usage,
        )
      end

      # OpenRouter hands back string keys; a hand-built response may not.
      def self.field(hash, key) = hash[key] || hash[key.to_sym]
    end
  end
end

__END__

describe "brute/usage_detection/open_router" do
  Response = Struct.new(:usage) unless defined?(Response)

  it "reads the OpenAI-shaped hash, string or symbol keys, and answers nil for no usage" do
    usage = Brute::UsageDetection::OpenRouter.detect(Response.new({
      "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15,
      "completion_tokens_details" => { "reasoning_tokens" => 4 },
    }))
    usage.input.should == 10
    usage.output.should == 5
    usage.total.should == 15
    usage.reasoning.should == 4

    symbols = Brute::UsageDetection::OpenRouter.detect(Response.new({ prompt_tokens: 1, completion_tokens: 2 }))
    symbols.input.should == 1
    symbols.output.should == 2
    symbols.total.should.be.nil

    Brute::UsageDetection::OpenRouter.detect(Response.new(nil)).should.be.nil
    Brute::UsageDetection::OpenRouter.detect(Object.new).should.be.nil
  end
end
