# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"
require "json"

module Brute
  class MessageTransport
    # MessageTransport for the official openai gem
    # (https://github.com/openai/openai-ruby). Brute does not require it —
    # you do:
    #
    #   require "openai"
    #
    #   client = OpenAI::Client.new(api_key: ENV["OPENAI_API_KEY"])
    #   response = client.chat.completions.create(
    #     model:    "gpt-5",
    #     messages: Brute::MessageTransport::OpenAI.dump_all(env[:messages]),
    #     tools:    ...,
    #   )
    #   Brute::MessageTransport::OpenAI.wrap_each(response) { |m| env[:messages] << m }
    class OpenAI < MessageTransport
      # Brute::Message -> a chat.completions message param hash.
      def self.dump(message)
        case message.role
        when :tool
          { role: "tool", tool_call_id: message.tool_call_id, content: message.content.to_s }
        when :assistant
          if message.tool_call?
            {
              role:       "assistant",
              content:    (message.content unless message.content.to_s.empty?),
              tool_calls: message.tool_calls.map { |tc|
                { id: tc.id, type: "function", function: { name: tc.name, arguments: JSON.generate(tc.arguments) } }
              },
            }
          else
            { role: "assistant", content: message.content }
          end
        else
          { role: message.role.to_s, content: message.content }
        end
      end

      # A chat completion response's messages (one per choice).
      def messages
        return @result.choices.map(&:message) if @result.respond_to?(:choices)

        super
      end

      private

        # An OpenAI chat completion message -> Brute::Message. Tool call
        # arguments arrive as a JSON string; parse them into a Hash.
        def wrap(message)
          tool_calls = message.tool_calls&.map do |tc|
            arguments = begin
              JSON.parse(tc.function.arguments.to_s)
            rescue JSON::ParserError
              {}
            end
            Brute::ToolCall.new(id: tc.id, name: tc.function.name, arguments: arguments)
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

describe "brute/message_transport/openai" do
  require "brute/messages"

  # Duck-typed stand-ins for the openai gem's response objects so these
  # specs don't need the gem loaded.
  fake_function  = Struct.new(:name, :arguments, keyword_init: true)
  fake_tool_call = Struct.new(:id, :function, keyword_init: true)
  fake_message   = Struct.new(:role, :content, :tool_calls, keyword_init: true)
  fake_choice    = Struct.new(:message, keyword_init: true)
  fake_response  = Struct.new(:choices, keyword_init: true)

  it "dumps a tool result to the wire format" do
    m = Brute::Message.new(role: :tool, content: "ok", tool_call_id: "tc1")
    Brute::MessageTransport::OpenAI.dump(m).should ==
      { role: "tool", tool_call_id: "tc1", content: "ok" }
  end

  it "dumps assistant tool calls with JSON-encoded arguments" do
    m = Brute::Message.new(role: :assistant, content: "",
                           tool_calls: [{ id: "tc1", name: "shell", arguments: { "command" => "ls" } }])
    dumped = Brute::MessageTransport::OpenAI.dump(m)
    dumped[:tool_calls].first[:function][:arguments].should == '{"command":"ls"}'
  end

  it "unpacks a chat completion's choices and parses arguments" do
    tc = fake_tool_call.new(id: "tc1", function: fake_function.new(name: "shell", arguments: '{"command":"ls"}'))
    response = fake_response.new(choices: [
      fake_choice.new(message: fake_message.new(role: "assistant", content: nil, tool_calls: [tc])),
    ])

    out = Brute::MessageTransport::OpenAI.new(response).wrap_each.to_a.first
    out.role.should == :assistant
    out.tool_calls.first.arguments.should == { "command" => "ls" }
  end
end
