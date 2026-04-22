# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Tools
    class Delegate < LLM::Tool
      name "delegate"
      description "Delegate a research or analysis task to a specialist sub-agent. " \
                  "The sub-agent can read files and search but cannot write or execute commands. " \
                  "Use for code analysis, understanding patterns, or gathering information."

      param :task, String, "A clear, detailed description of the research task", required: true

      def call(task:)
        provider = Brute.provider
        sub = LLM::Context.new(provider, tools: [FSRead, FSSearch])

        prompt = sub.prompt do
          system "You are a research agent. Analyze code, explain patterns, and answer questions. " \
                 "You have read-only access to the filesystem. Be thorough and precise."
          user task
        end

        # Run a manual tool loop (max 10 rounds)
        res = sub.talk(prompt)
        rounds = 0
        while sub.functions.any? && rounds < 10
          res = sub.talk(sub.functions.map(&:call))
          rounds += 1
        end

        {result: extract_content(res, sub)}
      end

      private

      # Safely extract text content from the sub-agent response.
      #
      # When the LLM returns only tool calls (no text content block),
      # res.content raises NoMethodError because the response adapter's
      # choices array is empty (it only maps over text blocks), or
      # returns nil when the response has no text. Fall back to the
      # last assistant text in the conversation history.
      def extract_content(res, context)
        text = begin
          res.content
        rescue NoMethodError
          nil
        end
        return text if text.is_a?(::String) && !text.empty?

        last_assistant = context.messages.to_a
          .select(&:assistant?)
          .reverse
          .find { |m| m.content.is_a?(::String) && !m.content.empty? }
        last_assistant&.content || "(sub-agent completed but produced no text response)"
      end
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  FakeMsg = Struct.new(:role, :content) do
    def assistant?; role == :assistant; end
  end

  def fake_context(messages)
    msgs_obj = Object.new
    msgs_obj.define_singleton_method(:to_a) { messages }
    ctx = Object.new
    ctx.define_singleton_method(:messages) { msgs_obj }
    ctx
  end

  delegate = Brute::Tools::Delegate.new

  it "returns content when response has text" do
    res = MockResponse.new(content: "analysis complete")
    delegate.send(:extract_content, res, fake_context([])).should == "analysis complete"
  end

  it "falls back to last assistant text on NoMethodError" do
    bad_res = Object.new
    bad_res.define_singleton_method(:content) { raise NoMethodError }
    ctx = fake_context([FakeMsg.new(:user, "input"), FakeMsg.new(:assistant, "found the answer")])
    delegate.send(:extract_content, bad_res, ctx).should == "found the answer"
  end

  it "returns fallback when no assistant messages exist" do
    bad_res = Object.new
    bad_res.define_singleton_method(:content) { raise NoMethodError }
    delegate.send(:extract_content, bad_res, fake_context([])).should == "(sub-agent completed but produced no text response)"
  end

  it "skips assistant messages with empty content" do
    bad_res = Object.new
    bad_res.define_singleton_method(:content) { raise NoMethodError }
    ctx = fake_context([FakeMsg.new(:assistant, "real answer"), FakeMsg.new(:assistant, "")])
    delegate.send(:extract_content, bad_res, ctx).should == "real answer"
  end

  it "falls back to last assistant on nil content" do
    nil_res = Struct.new(:content).new(nil)
    ctx = fake_context([FakeMsg.new(:assistant, "previous answer")])
    delegate.send(:extract_content, nil_res, ctx).should == "previous answer"
  end

  it "falls back to last assistant on empty string content" do
    empty_res = Struct.new(:content).new("")
    ctx = fake_context([FakeMsg.new(:assistant, "previous answer")])
    delegate.send(:extract_content, empty_res, ctx).should == "previous answer"
  end
end
