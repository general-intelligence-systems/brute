# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Prompts
    module Identity
      def self.call(ctx)
        Prompts.read("identity", ctx[:provider_name])
      end
    end
  end
end

test do
  it "returns a string for anthropic" do
    Brute::Prompts::Identity.call(provider_name: "anthropic").should.be.kind_of(String)
  end

  it "returns non-empty text for anthropic" do
    Brute::Prompts::Identity.call(provider_name: "anthropic").should.not.be.empty
  end

  it "returns non-empty text for openai" do
    Brute::Prompts::Identity.call(provider_name: "openai").should.not.be.empty
  end

  it "falls back to default for unknown providers" do
    default_text = Brute::Prompts::Identity.call(provider_name: "default")
    unknown_text = Brute::Prompts::Identity.call(provider_name: "nonexistent_provider")
    unknown_text.should == default_text
  end

  it "returns different text for different providers" do
    anthropic = Brute::Prompts::Identity.call(provider_name: "anthropic")
    openai = Brute::Prompts::Identity.call(provider_name: "openai")
    (anthropic != openai).should.be.true
  end
end
