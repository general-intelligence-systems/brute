# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  it "returns a string" do
    Brute::Prompts::BuildSwitch.call({}).should.be.kind_of(String)
  end

  it "wraps content in system-reminder tags" do
    Brute::Prompts::BuildSwitch.call({}).should =~ /system-reminder/
  end

  it "announces mode change from plan to build" do
    Brute::Prompts::BuildSwitch.call({}).should =~ /plan to build/
  end

  it "states no longer in read-only mode" do
    Brute::Prompts::BuildSwitch.call({}).should =~ /no longer in read-only mode/
  end

  it "permits tool use" do
    Brute::Prompts::BuildSwitch.call({}).should =~ /permitted to make file changes/
  end

  it "ignores context (static content)" do
    Brute::Prompts::BuildSwitch.call({ agent_switched: "build" }).should == Brute::Prompts::BuildSwitch.call({})
  end
end
