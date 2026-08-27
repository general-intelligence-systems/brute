# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/usage_detection/usage"

module Brute
  module UsageDetection
    # llm.rb models usage as its own LLM::Usage value object. Note it answers
    # 0, not nil, for anything the provider left out — that is llm.rb's
    # reading of the response and it is reported as given.
    module LLMrb
      def self.detect(response)
        if response.respond_to?(:usage)
          usage = response.usage
          if usage.nil?
            nil
          else
            Usage.new(
              input:       read(usage, :input_tokens),
              output:      read(usage, :output_tokens),
              total:       read(usage, :total_tokens),
              reasoning:   read(usage, :reasoning_tokens),
              cache_read:  read(usage, :cache_read_tokens),
              cache_write: read(usage, :cache_write_tokens),
              raw:         usage,
            )
          end
        else
          nil
        end
      end

      def self.read(usage, name) = usage.respond_to?(name) ? usage.public_send(name) : nil
    end
  end
end

__END__

describe "brute/usage_detection/llmrb" do
  LLMrbUsage = Struct.new(:input_tokens, :output_tokens, :total_tokens, :reasoning_tokens,
                          :cache_read_tokens, :cache_write_tokens) unless defined?(LLMrbUsage)
  LLMrbResponse = Struct.new(:usage) unless defined?(LLMrbResponse)

  it "reports LLM::Usage as given, and answers nil when there is no usage to read" do
    usage = Brute::UsageDetection::LLMrb.detect(LLMrbResponse.new(LLMrbUsage.new(10, 5, 15, 0, 0, 0)))

    usage.input.should == 10
    usage.output.should == 5
    usage.total.should == 15
    usage.reasoning.should == 0 # llm.rb's own zero, reported as given

    Brute::UsageDetection::LLMrb.detect(LLMrbResponse.new(nil)).should.be.nil
    Brute::UsageDetection::LLMrb.detect(Object.new).should.be.nil
  end
end
