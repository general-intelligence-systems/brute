# frozen_string_literal: true

RSpec.describe Brute::Middleware::ToolErrorTracking do
  let(:response) { MockResponse.new(content: "tracked") }
  let(:inner_app) { ->(_env) { response } }
  let(:middleware) { described_class.new(inner_app, max_failures: 3) }

  it "passes the response through" do
    env = build_env
    result = middleware.call(env)
    expect(result).to eq(response)
  end

  it "reports zero tool calls when tool_results is nil" do
    env = build_env(tool_results: nil)
    middleware.call(env)

    expect(env[:metadata][:tool_calls]).to eq(0)
    expect(env[:metadata][:tool_errors]).to eq({})
    expect(env[:metadata][:tool_error_limit_reached]).to be false
  end

  it "counts total tool calls from tool_results" do
    results = [
      ["fs_read", { content: "data" }],
      ["shell", { output: "ok" }],
      ["fs_write", { success: true }],
    ]
    env = build_env(tool_results: results)
    middleware.call(env)

    expect(env[:metadata][:tool_calls]).to eq(3)
  end

  it "counts per-tool errors from results with error key" do
    results = [
      ["fs_read", { error: "not found" }],
      ["fs_read", { error: "permission denied" }],
      ["shell", { output: "ok" }],
    ]
    env = build_env(tool_results: results)
    middleware.call(env)

    expect(env[:metadata][:tool_errors]).to eq({ "fs_read" => 2 })
  end

  it "sets tool_error_limit_reached when a tool hits max_failures" do
    results = [
      ["fs_read", { error: "fail 1" }],
      ["fs_read", { error: "fail 2" }],
      ["fs_read", { error: "fail 3" }],
    ]
    env = build_env(tool_results: results)
    middleware.call(env)

    expect(env[:metadata][:tool_error_limit_reached]).to be true
  end

  it "does not flag below the threshold" do
    results = [
      ["fs_read", { error: "fail 1" }],
      ["fs_read", { error: "fail 2" }],
    ]
    env = build_env(tool_results: results)
    middleware.call(env)

    expect(env[:metadata][:tool_error_limit_reached]).to be false
  end

  it "accumulates counts across multiple calls" do
    env1 = build_env(tool_results: [["fs_read", { error: "fail" }]])
    middleware.call(env1)

    env2 = build_env(tool_results: [["fs_read", { error: "fail again" }], ["shell", { output: "ok" }]])
    middleware.call(env2)

    expect(env2[:metadata][:tool_calls]).to eq(3) # 1 + 2
    expect(env2[:metadata][:tool_errors]).to eq({ "fs_read" => 2 })
  end

  it "clears counters on reset!" do
    env = build_env(tool_results: [["fs_read", { error: "fail" }]])
    middleware.call(env)

    middleware.reset!

    env2 = build_env(tool_results: nil)
    middleware.call(env2)

    expect(env2[:metadata][:tool_calls]).to eq(0)
    expect(env2[:metadata][:tool_errors]).to eq({})
  end
end
