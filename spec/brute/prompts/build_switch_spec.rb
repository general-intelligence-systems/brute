# frozen_string_literal: true

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
