# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"

module Brute
  class MessageTransport
    class RubyLLM < MessageTransport

      # What the provider reported about this call — the transport knows its
      # own library's shape, so it knows which detector to ask.
      def self.usage_metrics(message)
        Brute::UsageDetection::RubyLLM.detect(message)
      end

      # Brute::Message -> RubyLLM::Message (tool calls as ruby_llm's id-keyed hash).
      def self.dump(message, model: nil)
        tool_calls = message.tool_calls&.to_h do |tc|
          [tc.id, ::RubyLLM::ToolCall.new(id: tc.id, name: tc.name, arguments: tc.arguments)]
        end

        ::RubyLLM::Message.new(
          role:         message.role,
          content:      message.content,
          tool_calls:   tool_calls,
          tool_call_id: message.tool_call_id,
          thinking:     thinking(message),
        )
      end

      # RubyLLM::Thinking.build answers nil when there is nothing to say, and
      # takes the signature back exactly as it came. The signature lives on
      # the block that was signed, not on the sequence.
      def self.thinking(message)
        if message.reasoning
          ::RubyLLM::Thinking.build(
            text:      message.reasoning.text,
            signature: message.reasoning.blocks.find(&:signed?)&.signature,
          )
        end
      end

      private

      # RubyLLM::Message -> Brute::Message.
        def wrap(message)
          raw_calls = message.tool_calls
          if raw_calls.respond_to?(:values)
            calls_list = raw_calls.values
        else
          calls_list = raw_calls
        end

          tool_calls = calls_list&.map do |tc|
            Brute::ToolCall.new(
              id:        tc.id,
              name:      tc.name,
              arguments: tc.arguments,
            )
          end

          Brute::Message.new(
            role:         message.role,
            content:      message.content&.to_s, # Preserves nil safely
            tool_calls:   tool_calls,
            tool_call_id: message.tool_call_id,
            reasoning:    reasoning(message),
          )
        end

        # RubyLLM models it as a Thinking, carrying the text and the
        # provider's signature for it.
        def reasoning(message)
          if message.respond_to?(:thinking) && message.thinking
            Brute::Reasoning.build(text: message.thinking.text, signature: message.thinking.signature)
          end
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

  it "sends thinking back with the signature its block carried" do
    # ruby_llm models thinking as one text and one signature, so a sequence of
    # blocks flattens to its text and the signature of the block carrying one.
    require "ruby_llm"

    m = Brute::Message.new(role: :assistant, content: "done", reasoning: {
      blocks: [{ type: :text, text: "thought it through", signature: "sig-1" }],
    })

    thinking = Brute::MessageTransport::RubyLLM.dump(m).thinking
    thinking.text.should == "thought it through"
    thinking.signature.should == "sig-1"
  end

  it "wraps ruby_llm's id-keyed tool_calls hash into a flat list" do
    tc = fake_tool_call.new(id: "tc1", name: "shell", arguments: { "command" => "ls" })
    m = fake_message.new(role: :assistant, content: "", tool_calls: { "tc1" => tc })

    out = Brute::MessageTransport::RubyLLM.new(m).wrap_each.to_a.first
    out.tool_calls.first.should == Brute::ToolCall.new(id: "tc1", name: "shell", arguments: { "command" => "ls" })
  end
end
