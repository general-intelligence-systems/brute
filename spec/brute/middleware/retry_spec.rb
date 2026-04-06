# frozen_string_literal: true

RSpec.describe Brute::Middleware::Retry do
  let(:response) { MockResponse.new(content: "success") }

  it "returns the response on first successful call" do
    app, calls = mock_inner_app(response: response)
    middleware = described_class.new(app)
    env = build_env

    result = middleware.call(env)

    expect(result).to eq(response)
    expect(calls.size).to eq(1)
  end

  it "retries on LLM::RateLimitError and succeeds" do
    app = flaky_inner_app(LLM::RateLimitError, fail_count: 2, response: response)
    middleware = described_class.new(app, max_attempts: 3, base_delay: 2)
    allow(middleware).to receive(:sleep)
    env = build_env

    result = middleware.call(env)

    expect(result).to eq(response)
    expect(env[:metadata][:retry_attempt]).to eq(2)
  end

  it "retries on LLM::ServerError and succeeds" do
    app = flaky_inner_app(LLM::ServerError, fail_count: 1, response: response)
    middleware = described_class.new(app, max_attempts: 3, base_delay: 2)
    allow(middleware).to receive(:sleep)
    env = build_env

    result = middleware.call(env)

    expect(result).to eq(response)
    expect(env[:metadata][:retry_attempt]).to eq(1)
  end

  it "re-raises after exhausting all attempts" do
    app = failing_inner_app(LLM::RateLimitError, message: "rate limited")
    middleware = described_class.new(app, max_attempts: 3, base_delay: 2)
    allow(middleware).to receive(:sleep)
    env = build_env

    expect { middleware.call(env) }.to raise_error(LLM::RateLimitError, "rate limited")
    expect(env[:metadata][:last_error]).to eq("rate limited")
  end

  it "does not retry non-retryable errors" do
    call_count = 0
    app = ->(_env) { call_count += 1; raise ArgumentError, "bad input" }
    middleware = described_class.new(app)
    env = build_env

    expect { middleware.call(env) }.to raise_error(ArgumentError)
    expect(call_count).to eq(1)
  end

  it "sleeps with exponential backoff delays" do
    app = flaky_inner_app(LLM::RateLimitError, fail_count: 2, response: response)
    middleware = described_class.new(app, max_attempts: 3, base_delay: 2)
    allow(middleware).to receive(:sleep)
    env = build_env

    middleware.call(env)

    # base_delay ** attempts: 2**1 = 2, 2**2 = 4
    expect(middleware).to have_received(:sleep).with(2).ordered
    expect(middleware).to have_received(:sleep).with(4).ordered
  end

  it "records retry_delay in metadata" do
    app = flaky_inner_app(LLM::RateLimitError, fail_count: 1, response: response)
    middleware = described_class.new(app, max_attempts: 3, base_delay: 3)
    allow(middleware).to receive(:sleep)
    env = build_env

    middleware.call(env)

    # base_delay ** attempts: 3**1 = 3
    expect(env[:metadata][:retry_delay]).to eq(3)
  end
end
