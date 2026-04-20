# frozen_string_literal: true

module Brute
  module Prompts
    module Instructions
      def self.call(ctx)
        rules = ctx[:custom_rules]
        return nil if rules.nil? || rules.strip.empty?

        <<~TXT
          # Project-Specific Rules

          #{rules}
        TXT
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Prompts::Instructions do
    it "returns nil when custom_rules is nil" do
      expect(described_class.call(custom_rules: nil)).to be_nil
    end

    it "returns nil when custom_rules is empty" do
      expect(described_class.call(custom_rules: "")).to be_nil
    end

    it "returns nil when custom_rules is whitespace-only" do
      expect(described_class.call(custom_rules: "   \n  ")).to be_nil
    end

    it "wraps custom_rules in a Project-Specific Rules header" do
      text = described_class.call(custom_rules: "Always use tabs.")
      expect(text).to include("Project-Specific Rules")
      expect(text).to include("Always use tabs.")
    end
  end
end
