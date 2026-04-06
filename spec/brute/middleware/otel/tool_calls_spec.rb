# frozen_string_literal: true

RSpec.describe Brute::Middleware::OTel::ToolCalls do
  let(:response) { MockResponse.new(content: "here's my plan") }
  let(:inner_app) { ->(_env) { response } }
  let(:middleware) { described_class.new(inner_app) }

  it "passes the response through unchanged" do
    env = build_env
    result = middleware.call(env)
    expect(result).to eq(response)
  end

  context "when env[:span] is nil" do
    it "passes through without error even with pending functions" do
      ctx = build_env[:context]
      fn = double("function", name: "fs_read", id: "tc_001", arguments: { "path" => "/tmp" })
      allow(ctx).to receive(:functions).and_return([fn])

      env = build_env(context: ctx)
      result = middleware.call(env)
      expect(result).to eq(response)
    end
  end

  context "when env[:span] is present" do
    let(:span) { mock_span }

    it "does nothing when there are no pending functions" do
      ctx = build_env[:context]
      allow(ctx).to receive(:functions).and_return([])

      env = build_env(context: ctx, span: span)
      middleware.call(env)

      expect(span).not_to have_received(:add_event)
      expect(span).not_to have_received(:set_attribute)
    end

    it "does nothing when functions is nil" do
      ctx = build_env[:context]
      allow(ctx).to receive(:functions).and_return(nil)

      env = build_env(context: ctx, span: span)
      middleware.call(env)

      expect(span).not_to have_received(:add_event)
    end

    it "records a tool_call event per pending function" do
      ctx = build_env[:context]
      fn1 = double("function", name: "fs_read", id: "tc_001", arguments: { "path" => "/src/main.rb" })
      fn2 = double("function", name: "shell", id: "tc_002", arguments: { "command" => "rspec" })
      allow(ctx).to receive(:functions).and_return([fn1, fn2])

      env = build_env(context: ctx, span: span)
      middleware.call(env)

      expect(span).to have_received(:set_attribute).with("brute.tool_calls.count", 2)
      expect(span).to have_received(:add_event).with(
        "tool_call",
        attributes: hash_including(
          "tool.name" => "fs_read",
          "tool.id" => "tc_001"
        )
      )
      expect(span).to have_received(:add_event).with(
        "tool_call",
        attributes: hash_including(
          "tool.name" => "shell",
          "tool.id" => "tc_002"
        )
      )
    end

    it "serializes arguments as JSON" do
      ctx = build_env[:context]
      args = { "path" => "/tmp/test.rb", "content" => "puts 'hi'" }
      fn = double("function", name: "fs_write", id: "tc_003", arguments: args)
      allow(ctx).to receive(:functions).and_return([fn])

      env = build_env(context: ctx, span: span)
      middleware.call(env)

      expect(span).to have_received(:add_event).with(
        "tool_call",
        attributes: hash_including("tool.arguments" => args.to_json)
      )
    end

    it "handles nil arguments" do
      ctx = build_env[:context]
      fn = double("function", name: "todo_read", id: "tc_004", arguments: nil)
      allow(ctx).to receive(:functions).and_return([fn])

      env = build_env(context: ctx, span: span)
      middleware.call(env)

      expect(span).to have_received(:add_event).with(
        "tool_call",
        attributes: { "tool.name" => "todo_read", "tool.id" => "tc_004" }
      )
    end
  end
end
