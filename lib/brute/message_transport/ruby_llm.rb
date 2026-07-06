# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"

module Brute
  class MessageTransport
    # MessageTransport for the ruby_llm gem (https://rubyllm.com).
    # Brute does not require ruby_llm — you do:
    #
    #   require "ruby_llm"
    #
    #   response = provider.complete(
    #     Brute::MessageTransport::RubyLLM.dump_all(env[:messages]),
    #     tools: ..., model: model,
    #   )
    #   Brute::MessageTransport::RubyLLM.wrap_each(response) { |m| env[:messages] << m }
    class RubyLLM < MessageTransport
      # Brute::Message -> RubyLLM::Message (tool calls as ruby_llm's
      # id-keyed hash).
      def self.dump(message)
        tool_calls = message.tool_calls&.each_with_object({}) do |tc, hash|
          hash[tc.id] = ::RubyLLM::ToolCall.new(id: tc.id, name: tc.name, arguments: tc.arguments)
        end

        ::RubyLLM::Message.new(
          role:         message.role,
          content:      message.content,
          tool_calls:   tool_calls,
          tool_call_id: message.tool_call_id,
        )
      end

      private

        # RubyLLM::Message -> Brute::Message.
        def wrap(message)
          tool_calls = message.tool_calls&.values&.map do |tc|
            Brute::ToolCall.new(id: tc.id, name: tc.name, arguments: tc.arguments)
          end

          Brute::Message.new(
            role:         message.role,
            content:      message.content.to_s,
            tool_calls:   tool_calls,
            tool_call_id: message.tool_call_id,
          )
        end
    end
  end
end

__END__

describe "brute/message_transport/ruby_llm" do
  require "brute/messages"

  # Duck-typed stand-ins for RubyLLM::Message / RubyLLM::ToolCall so these
  # specs don't need the gem loaded.
  fake_tool_call = Struct.new(:id, :name, :arguments, keyword_init: true)
  fake_message   = Struct.new(:role, :content, :tool_calls, :tool_call_id, keyword_init: true)

  it "wraps a plain assistant message" do
    m = fake_message.new(role: :assistant, content: "hi")
    out = Brute::MessageTransport::RubyLLM.new(m).wrap_each.to_a
    out.first.should.be.kind_of?(Brute::Message)
    out.first.content.should == "hi"
  end

  it "wraps ruby_llm's id-keyed tool_calls hash into a flat list" do
    tc = fake_tool_call.new(id: "tc1", name: "shell", arguments: { "command" => "ls" })
    m = fake_message.new(role: :assistant, content: "", tool_calls: { "tc1" => tc })

    out = Brute::MessageTransport::RubyLLM.new(m).wrap_each.to_a.first
    out.tool_calls.first.should == Brute::ToolCall.new(id: "tc1", name: "shell", arguments: { "command" => "ls" })
  end
end
