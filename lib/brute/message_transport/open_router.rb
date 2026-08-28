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
      # OpenRouter takes reasoning back either way: `reasoning_details` is
      # the sequence the model produced, each entry carrying its own type,
      # payload and signature, and `reasoning` is the same thinking as plain
      # prose. The details are the complete form, so they are what goes when
      # there are details to send; prose that was only ever prose -- read off
      # a `reasoning` field, or off a library that reports nothing else --
      # goes as prose, because a details array built around it would be a
      # sequence the model never produced.
      #
      # Which of the two is a property of what was stored, not a judgement
      # about where the turn is headed. Where it is headed is the caller's to
      # decide; this only turns one shape into the other.
      def self.dump(message, model: nil)
        message.to_h.tap do |hash|
          # What Message#to_h holds is brute's own shape, which is not the
          # wire's: whatever goes out under these keys is put there here.
          hash.delete(:reasoning)

          reasoning = message.reasoning

          if reasoning&.detailed?
            hash[:reasoning_details] = reasoning.blocks.map { |block| detail(block) }
          elsif reasoning && !reasoning.text.empty?
            hash[:reasoning] = reasoning.text
          end
        end
      end

      # Each type names its own payload: reasoning text carries `text` and the
      # `signature` that verifies it, a summary carries `summary`, and an
      # encrypted item carries `data`. Written under the wrong key the payload
      # is simply lost, which for an encrypted item is the whole of it.
      def self.detail(block)
        named = {
          type:   "reasoning.#{block.type}",
          format: block.format,
          id:     block.id,
          index:  block.index,
        }

        case block.type
        when :encrypted
          named.merge(data: block.signature).compact
        when :summary
          named.merge(summary: block.text).compact
        else
          named.merge(text: block.text, signature: block.signature).compact
        end
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

        # The type names the payload's key, so it says which one to read.
        def block(detail)
          type = detail[:type].to_s.split(".").last.to_s

          Brute::ReasoningBlock.new(
            type:      type.empty? ? :text : type.to_sym,
            text:      detail[:text] || detail[:summary],
            signature: detail[:signature] || detail[:data],
            # Straight off the wire. `format` names a structure OpenRouter
            # documents a closed set of ("anthropic-claude-v1",
            # "openai-responses-v1", ... "unknown"); a model id is not one of
            # them, so where the wire named none, none is stored.
            format:    detail[:format],
            id:        detail[:id],
            index:     detail[:index],
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

    # Signed thinking goes back as the details array, entry for entry. The
    # details are the complete form, so they carry the turn on their own --
    # `reasoning` is the same thinking as prose, and sending both says it
    # twice.
    signed = Struct.new(:choices, :model).new([{ "message" => {
      "role" => "assistant", "content" => "",
      "reasoning_details" => [{ "type" => "reasoning.text", "text" => "step by step", "signature" => "sig-1" }],
    } }], "anthropic/claude-sonnet-4")

    back = Brute::MessageTransport::OpenRouter.dump(Brute::MessageTransport::OpenRouter.new(signed).wrap_each.to_a.first)
    back.key?(:reasoning).should.be.false
    back[:reasoning_details].should == [
      { type: "reasoning.text", text: "step by step", signature: "sig-1" },
    ]

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

  it "round-trips every detail type under its own payload key" do
    # OpenRouter names each payload after its type: a summary's prose is
    # `summary`, an encrypted item's payload is `data`, and only reasoning
    # text carries a `signature`. Read or written under the wrong key, the
    # payload is simply lost -- and an encrypted item is the case where the
    # plaintext alone is not enough.
    details = [
      { "type" => "reasoning.text", "text" => "step by step", "signature" => "sig-1",
        "format" => "anthropic-claude-v1", "id" => "r-1", "index" => 0 },
      { "type" => "reasoning.summary", "summary" => "weighed the constraints",
        "format" => "anthropic-claude-v1", "id" => "r-2", "index" => 1 },
      { "type" => "reasoning.encrypted", "data" => "b64blob",
        "format" => "anthropic-claude-v1", "id" => "r-3", "index" => 2 },
    ]

    response = Struct.new(:choices).new([
      { "message" => { "role" => "assistant", "content" => "", "reasoning_details" => details } },
    ])

    wrapped = Brute::MessageTransport::OpenRouter.new(response).wrap_each.to_a.first
    wrapped.reasoning.text.should == "step by step\nweighed the constraints"

    back = Brute::MessageTransport::OpenRouter.dump(wrapped, model: "anthropic/claude-sonnet-4")
    back[:reasoning_details].should == details.map { |detail| detail.transform_keys(&:to_sym) }
  end

  it "sends an opaque payload out as reasoning.encrypted, under either name" do
    # The same Claude payload is :redacted when Anthropic logged it and
    # :encrypted when OpenRouter did. Either way it is not text, and its
    # payload belongs under data.
    [:redacted, :encrypted].each do |type|
      m = Brute::Message.new(role: :assistant, content: "done", reasoning: {
        blocks: [{ type: type, signature: "b64blob", format: "anthropic-claude-v1" }],
      })

      Brute::MessageTransport::OpenRouter.dump(m, model: "anthropic/claude-sonnet-4")[:reasoning_details]
        .should == [{ type: "reasoning.encrypted", data: "b64blob", format: "anthropic-claude-v1" }]
    end
  end

  it "stores the format the wire named, and no other" do
    # `format` names one of a closed set of structures OpenRouter documents
    # -- "anthropic-claude-v1", "openai-responses-v1", ... "unknown". A model
    # id is not one of them, so where the wire named no format, none is
    # stored and none is sent: an invented one is a value the API does not
    # take, and a value nothing else in here can read back.
    named = Struct.new(:choices, :model).new([
      { "message" => { "role" => "assistant", "content" => "done", "reasoning_details" => [
        { "type" => "reasoning.text", "text" => "step by step", "signature" => "sig-1",
          "format" => "anthropic-claude-v1" },
      ] } },
    ], "anthropic/claude-sonnet-4")

    unnamed = Struct.new(:choices, :model).new([
      { "message" => { "role" => "assistant", "content" => "done", "reasoning_details" => [
        { "type" => "reasoning.text", "text" => "step by step", "signature" => "sig-1" },
      ] } },
    ], "anthropic/claude-sonnet-4")

    Brute::MessageTransport::OpenRouter.new(named).wrap_each.to_a.first
      .reasoning.blocks.first.format.should == "anthropic-claude-v1"

    Brute::MessageTransport::OpenRouter.new(unnamed).wrap_each.to_a.first
      .reasoning.blocks.first.format.should.be.nil
  end

  it "sends the details sequence whole, entry for entry" do
    # "The entire sequence of consecutive reasoning blocks must match the
    # outputs generated by the model; you cannot rearrange or modify the
    # sequence." So every entry goes, in order, as it was stored -- what the
    # turn is then sent to is the caller's to decide, not this.
    response = Struct.new(:choices).new([
      { "message" => { "role" => "assistant", "content" => "done", "reasoning_details" => [
        { "type" => "reasoning.text", "text" => "step by step", "signature" => "sig-1",
          "format" => "anthropic-claude-v1", "index" => 0 },
        { "type" => "reasoning.encrypted", "data" => "b64blob",
          "format" => "anthropic-claude-v1", "index" => 1 },
      ] } },
    ])

    wrapped = Brute::MessageTransport::OpenRouter.new(response).wrap_each.to_a.first

    Brute::MessageTransport::OpenRouter.dump(wrapped)[:reasoning_details].should == [
      { type: "reasoning.text", format: "anthropic-claude-v1", index: 0,
        text: "step by step", signature: "sig-1" },
      { type: "reasoning.encrypted", format: "anthropic-claude-v1", index: 1,
        data: "b64blob" },
    ]
  end

  it "does not invent a details sequence around plaintext reasoning" do
    # A sequence Brute made up is not one the model produced.
    plain = Brute::Message.new(role: :assistant, content: "done", reasoning: "just thinking")

    back = Brute::MessageTransport::OpenRouter.dump(plain, model: "anthropic/claude-sonnet-4")
    back[:reasoning].should == "just thinking"
    back.key?(:reasoning_details).should.be.false
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
