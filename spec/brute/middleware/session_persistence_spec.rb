# frozen_string_literal: true

RSpec.describe Brute::Middleware::SessionPersistence do
  let(:response) { MockResponse.new(content: "saved response") }
  let(:inner_app) { ->(_env) { response } }
  let(:session) { double("session", save: nil) }
  let(:middleware) { described_class.new(inner_app, session: session) }

  it "passes the response through unchanged" do
    env = build_env
    result = middleware.call(env)
    expect(result).to eq(response)
  end

  it "calls session.save with the context after a successful LLM call" do
    env = build_env
    middleware.call(env)
    expect(session).to have_received(:save).with(env[:context])
  end

  it "does not propagate session save failures" do
    allow(session).to receive(:save).and_raise(RuntimeError, "disk full")
    env = build_env

    expect { middleware.call(env) }.not_to raise_error
  end

  it "prints a warning to stderr on save failure" do
    allow(session).to receive(:save).and_raise(RuntimeError, "disk full")
    env = build_env

    expect { middleware.call(env) }.to output(/Session save failed: disk full/).to_stderr
  end
end
