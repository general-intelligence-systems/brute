# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"
require "brute/message_transport/ruby_open_ai"

module Brute
  class MessageTransport
    # MessageTransport for the langchainrb gem. Its LLM classes speak the
    # OpenAI-style wire format, so the message conversion is RubyOpenAI's —
    # what differs is usage, which langchainrb answers through per-provider
    # response methods rather than a usage object.
    class LangChain < RubyOpenAI
      def self.usage_metrics(response)
        Brute::UsageDetection::LangChain.detect(response)
      end
    end
  end
end

__END__

describe "brute/message_transport/lang_chain" do
  LangChainUsageResponse = Struct.new(:prompt_tokens, :completion_tokens, :total_tokens) unless defined?(LangChainUsageResponse)

  it "reads usage the langchainrb way and converts messages the OpenAI way" do
    usage = Brute::MessageTransport::LangChain.usage_metrics(LangChainUsageResponse.new(10, 5, 15))
    usage.input.should == 10
    usage.total.should == 15

    dumped = Brute::MessageTransport::LangChain.dump(Brute::Message.new(role: :user, content: "hi"))
    dumped[:role].should == "user"
    dumped[:content].should == "hi"
  end
end
