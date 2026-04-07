# frozen_string_literal: true

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
