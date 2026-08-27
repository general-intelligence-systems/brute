# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"
require "json"

module Brute
  class MessageTransport
    # MessageTransport for the open_router_enhanced gem
    # (https://github.com/estiens/open_router_enhanced). Brute does not
    # require it — you do:
    #
    #   require "open_router"
    class OpenRouter < MessageTransport

      # What the provider reported about this call — the transport knows its
      # own library's shape, so it knows which detector to ask.
      def self.usage_metrics(response)
        Brute::UsageDetection::OpenRouter.detect(response)
      end
      def self.dump(message)
        message.to_h
      end

      # An OpenRouter::Response's messages (one per choice; in practice
      # OpenRouter returns exactly one).
      def messages
        if @result.respond_to?(:choices)
          @result.choices.map { |choice| choice["message"] || choice[:message] }
        else
          super
        end
      end

      private

        def wrap(message)
          # Coerce string keys to symbol keys if necessary
          hash = message.to_h.transform_keys(&:to_sym)
          if hash.key?(:role)
            hash[:role] = hash[:role].to_sym
          end
          if hash[:tool_calls]
            hash[:tool_calls] = hash[:tool_calls].map { |tc| wrap_tool_call(tc) }
          end

          case hash
          in { role: (:system | :user | :assistant | :tool) }
            # Slice away provider extras (refusal, reasoning, model, ...)
            # that Brute::Message doesn't know.
            Brute::Message.new(
              **hash.slice(
                :role,
                :content,
                :tool_calls,
                :tool_call_id,
              ),
            )
          else
            raise "Unrecognised message format #{message.inspect}"
          end
        end

        # An OpenAI-wire tool call ({ id:, type:, function: { name:, arguments: JSON } })
        # -> the flat { id:, name:, arguments: Hash } Brute::Message understands.
        def wrap_tool_call(tool_call)
          tc = tool_call.to_h.transform_keys(&:to_sym)
          if tc[:function]
            function = tc[:function].to_h.transform_keys(&:to_sym)
            arguments = function[:arguments].to_s
            {
              id:        tc[:id],
              name:      function[:name],
              arguments: JSON.parse(arguments.empty? ? "{}" : arguments),
            }
          else
            tc
          end
        end
    end
  end
end

__END__

describe "brute/message_transport/open_router" do
  require "brute/messages"

  it "dumps a message to the wire format" do
    m = Brute::Message.new(role: :user, content: "hi")
    Brute::MessageTransport::OpenRouter.dump(m).should == { role: :user, content: "hi" }
  end

  it "wraps a response's choice messages with symbolised roles, dropping provider extras" do
    fake_response = Struct.new(:choices).new([
      { "message" => { "role" => "assistant", "content" => "hi there",
                       "refusal" => nil, "reasoning" => nil, "model" => "openrouter/auto" } },
    ])

    out = Brute::MessageTransport::OpenRouter.new(fake_response).wrap_each.to_a

    out.size.should == 1
    out.first.role.should == :assistant
    out.first.content.should == "hi there"
  end

  it "unwraps OpenAI-wire tool calls and parses their JSON arguments" do
    fake_response = Struct.new(:choices).new([
      { "message" => {
        "role" => "assistant", "content" => nil,
        "tool_calls" => [{ "id" => "tc1", "type" => "function",
                           "function" => { "name" => "shell", "arguments" => '{"command":"ls"}' } }],
      } },
    ])

    out = Brute::MessageTransport::OpenRouter.new(fake_response).wrap_each.to_a.first

    out.tool_call?.should.be.true
    out.tool_calls.first.id.should == "tc1"
    out.tool_calls.first.name.should == "shell"
    out.tool_calls.first.arguments.should == { "command" => "ls" }
  end
end
