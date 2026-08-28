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
      EmptyCompletion = Class.new(StandardError)

      # What the provider reported about this call — the transport knows its
      # own library's shape, so it knows which detector to ask.
      def self.usage_metrics(response)
        Brute::UsageDetection::OpenRouter.detect(response)
      end
      # Reasoning goes back up with the message it belongs to: a reasoning
      # model that called a tool has to see its own thinking on the next pass,
      # or it answers the tool call without the thinking that asked for it.
      #
      # OpenRouter takes it either as the plain `reasoning` string or as the
      # whole `reasoning_details` array, which is what carries the signature.
      # The sequence has to match what the model produced -- it may not be
      # rearranged or modified -- so what came back is what goes out.
      def self.dump(message, model: nil)
        message.to_h.tap do |hash|
          if message.reasoning
            hash[:reasoning] = message.reasoning.text

            # The details go back whole, in order, or not at all -- the
            # sequence has to match what the model produced. OpenRouter routes
            # to many providers, so "signed" is not enough: a Claude signature
            # is only good while the turn is still going to Claude. Switch
            # model mid-conversation and the plaintext survives while the
            # signatures, which the new provider cannot verify, do not.
            details = message.reasoning.blocks.select { |block| block.signed? && issued_by?(block, model) }

            unless details.empty?
              hash[:reasoning_details] = details.map { |block| detail(block) }
            end
          end
        end
      end

      # OpenRouter names both sides after the provider: a model id reads
      # "anthropic/claude-sonnet-4", a format "anthropic-claude-v1". Asked
      # about no model in particular, the format is taken at its word.
      def self.issued_by?(block, model)
        if model.nil? || block.format.nil?
          true
        else
          block.format.split("-").first == model.to_s.split("/").first
        end
      end

      def self.detail(block)
        {
          type:      block.type == :encrypted ? "reasoning.encrypted" : "reasoning.text",
          text:      block.text,
          signature: block.signature,
          format:    block.format,
          id:        block.id,
        }.compact
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
            # A completion that answered with nothing is not an answer. The
            # provider was paid for it and something came back -- reasoning,
            # a refusal, a field this does not know -- and appending it as an
            # empty assistant message loses the turn quietly: the loop stops
            # because it is not a tool result, and there is no reply in it.
            if hash[:role] == :assistant && hash[:content].to_s.strip.empty? && Array(hash[:tool_calls]).empty? && reasoning(hash).nil?
              raise EmptyCompletion, "the provider answered with no content and no tool calls: #{message.inspect}"
            end

            # Slice away provider extras (refusal, model, ...) that
            # Brute::Message doesn't know. Reasoning is not one of them: it is
            # the model's own thinking and it goes back up with the message.
            Brute::Message.new(
              **hash.slice(
                :role,
                :content,
                :tool_calls,
                :tool_call_id,
              ),
              reasoning: reasoning(hash),
            )
          else
            raise "Unrecognised message format #{message.inspect}"
          end
        end

        # reasoning_details is the sequence the model produced, each detail
        # naming its own format; `reasoning` is the same thing as plaintext.
        def reasoning(hash)
          details = Array(hash[:reasoning_details]).map { |detail| detail.to_h.transform_keys(&:to_sym) }

          if details.empty?
            Brute::Reasoning.build(text: hash[:reasoning])
          else
            Brute::Reasoning.build(blocks: details.map { |detail| block(detail) })
          end
        end

        # "reasoning.text" / "reasoning.summary" carry what was thought;
        # "reasoning.encrypted" carries a payload that is not ours to read.
        def block(detail)
          Brute::Reasoning::Block.new(
            type:      detail[:type].to_s.end_with?("encrypted") ? :encrypted : :text,
            text:      detail[:text],
            signature: detail[:signature] || detail[:data],
            format:    detail[:format],
            id:        detail[:id],
          )
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

  it "keeps the model's reasoning, and refuses a completion that answered with nothing at all" do
    # Reasoning is the model's own thinking, and it goes back up with the
    # message: a reasoning model that called a tool has to see it on the next
    # pass. Dropping it left an empty assistant message and a lost turn.
    thought = Struct.new(:choices).new([{ "message" => { "role" => "assistant", "content" => "", "reasoning" => "thought about it" } }])

    reasoned = Brute::MessageTransport::OpenRouter.new(thought).wrap_each.to_a.first
    reasoned.reasoning.text.should == "thought about it"
    Brute::MessageTransport::OpenRouter.dump(reasoned)[:reasoning].should == "thought about it"

    # Signed thinking goes back as the details array, unmodified, which is
    # what carries the signature the provider checks.
    signed = Struct.new(:choices).new([{ "message" => {
      "role" => "assistant", "content" => "",
      "reasoning_details" => [{ "type" => "reasoning.text", "text" => "step by step", "signature" => "sig-1" }],
    } }])

    back = Brute::MessageTransport::OpenRouter.dump(Brute::MessageTransport::OpenRouter.new(signed).wrap_each.to_a.first)
    back[:reasoning].should == "step by step"
    back[:reasoning_details].should == [{ type: "reasoning.text", text: "step by step", signature: "sig-1" }]

    # A tool call is an answer, even with nothing said alongside it.
    calling = Struct.new(:choices).new([
      { "message" => {
        "role" => "assistant", "content" => nil,
        "tool_calls" => [{ "id" => "tc1", "type" => "function", "function" => { "name" => "shell", "arguments" => "{}" } }],
      } },
    ])

    Brute::MessageTransport::OpenRouter.new(calling).wrap_each.to_a.first.tool_call?.should.be.true

    # Nothing said, nothing thought, nothing called: the provider was paid for
    # an answer and there is none, which is an error rather than a message.
    empty = Struct.new(:choices).new([{ "message" => { "role" => "assistant", "content" => "", "refusal" => nil } }])

    lambda { Brute::MessageTransport::OpenRouter.new(empty).wrap_each.to_a }
      .should.raise(Brute::MessageTransport::OpenRouter::EmptyCompletion)
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
