# frozen_string_literal: true

RSpec.describe Brute::Prompts::PlanReminder do
  subject(:text) { described_class.call({}) }

  it "returns a string" do
    expect(text).to be_a(String)
  end

  it "wraps content in system-reminder tags" do
    expect(text).to include("<system-reminder>")
    expect(text).to include("</system-reminder>")
  end

  it "declares READ-ONLY mode" do
    expect(text).to include("READ-ONLY")
  end

  it "forbids file edits" do
    expect(text).to include("STRICTLY FORBIDDEN")
  end

  it "states it supersedes other instructions" do
    expect(text).to include("supersedes any other instructions")
  end

  it "ignores context (static content)" do
    expect(described_class.call({ agent: "plan" })).to eq(described_class.call({}))
  end
end
