# frozen_string_literal: true

module Brute
  module Prompts
    module Identity
      def self.call(ctx)
        Prompts.read("identity", ctx[:provider_name])
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Prompts::Identity do
    it "returns provider-specific text for anthropic" do
      text = described_class.call(provider_name: "anthropic")
      expect(text).to be_a(String)
      expect(text).not_to be_empty
    end

    it "returns provider-specific text for openai" do
      text = described_class.call(provider_name: "openai")
      expect(text).to be_a(String)
      expect(text).not_to be_empty
    end

    it "returns provider-specific text for google" do
      text = described_class.call(provider_name: "google")
      expect(text).to be_a(String)
      expect(text).not_to be_empty
    end

    it "falls back to default.txt for unknown providers" do
      default_text = described_class.call(provider_name: "default")
      unknown_text = described_class.call(provider_name: "nonexistent_provider")
      expect(unknown_text).to eq(default_text)
    end

    it "returns different text for different providers" do
      anthropic = described_class.call(provider_name: "anthropic")
      openai = described_class.call(provider_name: "openai")
      expect(anthropic).not_to eq(openai)
    end
  end
end
