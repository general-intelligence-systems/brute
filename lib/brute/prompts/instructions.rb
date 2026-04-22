# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  it "returns nil when custom_rules is nil" do
    Brute::Prompts::Instructions.call(custom_rules: nil).should.be.nil
  end

  it "returns nil when custom_rules is empty" do
    Brute::Prompts::Instructions.call(custom_rules: "").should.be.nil
  end

  it "returns nil when custom_rules is whitespace-only" do
    Brute::Prompts::Instructions.call(custom_rules: "   \n  ").should.be.nil
  end

  it "wraps custom_rules in a Project-Specific Rules header" do
    Brute::Prompts::Instructions.call(custom_rules: "Always use tabs.").should =~ /Project-Specific Rules/
  end
end
