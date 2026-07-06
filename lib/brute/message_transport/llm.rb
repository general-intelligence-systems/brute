# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"
require "json"

module Brute
  class MessageTransport
    # MessageTransport for the llm.rb gem (https://github.com/llmrb/llm.rb).
    # Brute does not require llm.rb — you do:
    #
    #   require "llm"
    #
    #   llm = LLM.openai(key: ENV["OPENAI_API_KEY"])
    #   messages = Brute::MessageTransport::LLM.dump_all(env[:messages])
    #   response = llm.complete(messages.pop, role: nil, messages: messages, tools: ...)
    #   Brute::MessageTransport::LLM.wrap_each(response) { |m| env[:messages] << m }
    class LLM < MessageTransport
      # Brute::Message -> LLM::Message. Assistant tool calls carry llm.rb's
      # `original_tool_calls` extra (the provider wire format); tool results
      # become an LLM::Function::Return so llm.rb's request adapters emit
      # them correctly.
      def self.dump(message)
        case message.role
        when :tool
          ::LLM::Message.new(
            :tool,
            ::LLM::Function::Return.new(message.tool_call_id, nil, message.content.to_s),
          )
        when :assistant
          if message.tool_call?
            wire = message.tool_calls.map do |tc|
              { id: tc.id, type: "function", function: { name: tc.name, arguments: JSON.generate(tc.arguments) } }
            end
            ::LLM::Message.new(:assistant, message.content.to_s,
                               { tool_calls: wire, original_tool_calls: wire })
          else
            ::LLM::Message.new(:assistant, message.content)
          end
        else
          ::LLM::Message.new(message.role, message.content)
        end
      end

      private

        # LLM::Message (from an LLM::Response) -> Brute::Message.
        def wrap(message)
          tool_calls = if message.tool_call?
            message.tool_calls.map do |tc|
              Brute::ToolCall.new(id: tc.id, name: tc["name"], arguments: tc.arguments.to_h)
            end
          end

          Brute::Message.new(
            role:       message.role,
            content:    message.content.to_s,
            tool_calls: tool_calls,
          )
        end
    end
  end
end

__END__

describe "brute/message_transport/llm" do
  require "brute/messages"

  # Duck-typed stand-in for a response LLM::Message so these specs don't
  # need the gem loaded.
  fake_tool_call = Struct.new(:id, :arguments, keyword_init: true) do
    def [](key); key == "name" ? "shell" : nil; end
  end
  fake_message = Struct.new(:role, :content, :tool_calls, keyword_init: true) do
    def tool_call?; !tool_calls.nil? && tool_calls.any?; end
  end

  it "wraps a plain assistant message" do
    m = fake_message.new(role: "assistant", content: "hi")
    out = Brute::MessageTransport::LLM.new(m).wrap_each.to_a.first
    out.role.should == :assistant
    out.content.should == "hi"
  end

  it "wraps tool calls into Brute::ToolCall" do
    tc = fake_tool_call.new(id: "tc1", arguments: { "command" => "ls" })
    m = fake_message.new(role: "assistant", content: nil, tool_calls: [tc])

    out = Brute::MessageTransport::LLM.new(m).wrap_each.to_a.first
    out.tool_calls.first.should == Brute::ToolCall.new(id: "tc1", name: "shell", arguments: { "command" => "ls" })
  end
end
