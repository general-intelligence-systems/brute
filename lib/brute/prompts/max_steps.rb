# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  it "returns a string" do
    Brute::Prompts::MaxSteps.call({}).should.be.kind_of(String)
  end

  it "announces maximum steps reached" do
    Brute::Prompts::MaxSteps.call({}).should =~ /MAXIMUM STEPS REACHED/
  end

  it "states tools are disabled" do
    Brute::Prompts::MaxSteps.call({}).should =~ /Tools are disabled/
  end

  it "requires a text-only response" do
    Brute::Prompts::MaxSteps.call({}).should =~ /text ONLY/
  end

  it "ignores context (static content)" do
    Brute::Prompts::MaxSteps.call({ max_steps_reached: true }).should == Brute::Prompts::MaxSteps.call({})
  end
end
