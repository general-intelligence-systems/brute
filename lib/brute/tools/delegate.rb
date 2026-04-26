# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Tools
    class Delegate < RubyLLM::Tool
      description "Delegate a research or analysis task to a specialist sub-agent. " \
                  "The sub-agent can read files and search but cannot write or execute commands. " \
                  "Use for code analysis, understanding patterns, or gathering information."

      param :task, type: 'string', desc: "A clear, detailed description of the research task", required: true

      def name; "delegate"; end

      MAX_ROUNDS = 10

      def execute(task:)
        provider = Brute.provider
        llm = provider.ruby_llm_provider
        model_id = provider.default_model
        model = Brute::Middleware::ModelRef.new(model_id, 16_384)

        sub_tools = { read: FSRead.new, fs_search: FSSearch.new }

        messages = [
          RubyLLM::Message.new(
            role: :system,
            content: "You are a research agent. Analyze code, explain patterns, and answer questions. " \
                     "You have read-only access to the filesystem. Be thorough and precise."
          ),
          RubyLLM::Message.new(role: :user, content: task),
        ]

        response = nil
        MAX_ROUNDS.times do
          response = llm.complete(messages, tools: sub_tools, temperature: nil, model: model)
          messages << response

          break unless response.tool_call?

          response.tool_calls.each_value do |tc|
            tool = sub_tools[tc.name.to_sym]
            result = if tool
                       tool.call(tc.arguments)
                     else
                       { error: "Unknown tool: #{tc.name}" }
                     end
            content = result.is_a?(String) ? result : result.to_s
            messages << RubyLLM::Message.new(role: :tool, content: content, tool_call_id: tc.id)
          end
        end

        { result: extract_content(response, messages) }
      end

      private

      # Safely extract text content from the sub-agent response.
      def extract_content(response, messages)
        text = response&.content
        return text if text.is_a?(::String) && !text.empty?

        # Fall back to last assistant text in the conversation history
        last_assistant = messages
          .select { |m| m.role == :assistant }
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

  delegate = Brute::Tools::Delegate.new

  it "returns content when response has text" do
    res = RubyLLM::Message.new(role: :assistant, content: "analysis complete")
    delegate.send(:extract_content, res, []).should == "analysis complete"
  end

  it "falls back to last assistant text on nil content" do
    res = RubyLLM::Message.new(role: :assistant, content: "")
    msgs = [
      RubyLLM::Message.new(role: :user, content: "input"),
      RubyLLM::Message.new(role: :assistant, content: "found the answer"),
    ]
    delegate.send(:extract_content, res, msgs).should == "found the answer"
  end

  it "returns fallback when no assistant messages exist" do
    res = RubyLLM::Message.new(role: :assistant, content: "")
    delegate.send(:extract_content, res, []).should == "(sub-agent completed but produced no text response)"
  end

  it "skips assistant messages with empty content" do
    res = RubyLLM::Message.new(role: :assistant, content: "")
    msgs = [
      RubyLLM::Message.new(role: :assistant, content: "real answer"),
      RubyLLM::Message.new(role: :assistant, content: ""),
    ]
    delegate.send(:extract_content, res, msgs).should == "real answer"
  end
end
