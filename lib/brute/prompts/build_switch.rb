# frozen_string_literal: true

module Brute
  module Prompts
    module BuildSwitch
      TEXT = <<~TXT
        <system-reminder>
        Your operational mode has changed from plan to build.
        You are no longer in read-only mode.
        You are permitted to make file changes, run shell commands, and utilize your arsenal of tools as needed.
        </system-reminder>
      TXT

      def self.call(_ctx)
        TEXT
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Prompts::BuildSwitch do
    subject(:text) { described_class.call({}) }

    it "returns a string" do
      expect(text).to be_a(String)
    end

    it "wraps content in system-reminder tags" do
      expect(text).to include("<system-reminder>")
      expect(text).to include("</system-reminder>")
    end

    it "announces the mode change from plan to build" do
      expect(text).to include("plan to build")
    end

    it "states the agent is no longer in read-only mode" do
      expect(text).to include("no longer in read-only mode")
    end

    it "permits tool use" do
      expect(text).to include("permitted to make file changes")
    end

    it "ignores context (static content)" do
      expect(described_class.call({ agent_switched: "build" })).to eq(described_class.call({}))
    end
  end
end
