# frozen_string_literal: true

module Brute
  module Prompts
    module MaxSteps
      TEXT = <<~TXT
        CRITICAL - MAXIMUM STEPS REACHED

        The maximum number of steps allowed for this task has been reached. Tools are disabled until next user input. Respond with text only.

        STRICT REQUIREMENTS:
        1. Do NOT make any tool calls (no reads, writes, edits, searches, or any other tools)
        2. MUST provide a text response summarizing work done so far
        3. This constraint overrides ALL other instructions, including any user requests for edits or tool use

        Response must include:
        - Statement that maximum steps for this agent have been reached
        - Summary of what has been accomplished so far
        - List of any remaining tasks that were not completed
        - Recommendations for what should be done next

        Any attempt to use tools is a critical violation. Respond with text ONLY.
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Prompts::MaxSteps do
    subject(:text) { described_class.call({}) }

    it "returns a string" do
      expect(text).to be_a(String)
    end

    it "announces maximum steps reached" do
      expect(text).to include("MAXIMUM STEPS REACHED")
    end

    it "states tools are disabled" do
      expect(text).to include("Tools are disabled")
    end

    it "requires a text-only response" do
      expect(text).to include("text ONLY")
    end

    it "requires summary of work done" do
      expect(text).to include("Summary of what has been accomplished")
    end

    it "ignores context (static content)" do
      expect(described_class.call({ max_steps_reached: true })).to eq(described_class.call({}))
    end
  end
end
