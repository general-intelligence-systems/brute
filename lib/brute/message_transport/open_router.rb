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
          # What Message#to_h holds is brute's own shape, which is not the
          # wire's: whatever goes out under these keys is put there here.
          hash.delete(:reasoning)

          if message.reasoning
            # An encrypted payload has no prose in it, and an empty string is
            # not reasoning: the details carry it, or nothing does.
            unless message.reasoning.text.empty?
              hash[:reasoning] = message.reasoning.text
            end

            # The details go back whole, in order, or not at all -- the
            # sequence has to match what the model produced. OpenRouter routes
            # to many providers, so "signed" is not enough: a Claude signature
            # is only good while the turn is still going to Claude. Switch
            # model mid-conversation and the plaintext survives while the
            # signatures, which the new provider cannot verify, do not.
            # Whole or not at all: dropping an entry out of the middle is
            # modifying the sequence, which is what the provider forbids. A
            # plaintext-only reasoning has nothing signed in it, so no array
            # is invented around it.
            if message.reasoning.detailed? && message.reasoning.blocks.all? { |block| issued_by?(block, model) }
              hash[:reasoning_details] = message.reasoning.blocks.map { |block| detail(block) }
            end
          end
        end
      end

      # OpenRouter names both sides after the provider: a model id reads
      # "anthropic/claude-sonnet-4", a format "anthropic-claude-v1". Asked
      # about no model in particular, the format is taken at its word.
      def self.issued_by?(block, model)
        vendor = model.to_s.split("/").first

        if block.format.nil?
          # A signature that names no provider cannot be attributed to this
          # one; unsigned there is nothing to attribute and it passes.
          !block.signed?
        elsif vendor.nil? || vendor == model.to_s
          # No model, or an id that names no vendor: nothing to contradict the
          # format, so it is taken at its word rather than dropped silently.
          true
        else
          block.format.split("-").first == vendor
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

        def answering_model
          if @result.respond_to?(:model)
            @result.model
          end
        end

        # The type names the payload's key, so it says which one to read.
        def block(detail)
          type = detail[:type].to_s.split(".").last.to_s

          Brute::Reasoning::Block.new(
            type:      type.empty? ? :text : type.to_sym,
            text:      detail[:text] || detail[:summary],
            signature: detail[:signature] || detail[:data],
            # A provider that names no format still answered as some model,
            # and an unattributed signature is one nobody may replay -- so the
            # model that produced it stands in for the format it did not send.
            format:    detail[:format] || answering_model,
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

    # Signed thinking goes back as the details array, unmodified, which is
    # what carries the signature the provider checks.
    # A detail that names no format is stamped with the model that answered,
    # because a signature nobody claims is one nobody may replay.
    signed = Struct.new(:choices, :model).new([{ "message" => {
      "role" => "assistant", "content" => "",
      "reasoning_details" => [{ "type" => "reasoning.text", "text" => "step by step", "signature" => "sig-1" }],
    } }], "anthropic/claude-sonnet-4")

    back = Brute::MessageTransport::OpenRouter.dump(Brute::MessageTransport::OpenRouter.new(signed).wrap_each.to_a.first)
    back[:reasoning].should == "step by step"
    back[:reasoning_details].should == [
      { type: "reasoning.text", format: "anthropic/claude-sonnet-4", text: "step by step", signature: "sig-1" },
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

  it "sends the details sequence whole, or not at all" do
    # "The entire sequence of consecutive reasoning blocks must match the
    # outputs generated by the model; you cannot rearrange or modify the
    # sequence." A subset of it is a modified sequence, so a turn going to
    # another provider keeps the plaintext and drops the array entire.
    response = Struct.new(:choices).new([
      { "message" => { "role" => "assistant", "content" => "done", "reasoning_details" => [
        { "type" => "reasoning.text", "text" => "step by step", "signature" => "sig-1",
          "format" => "anthropic-claude-v1" },
      ] } },
    ])

    wrapped = Brute::MessageTransport::OpenRouter.new(response).wrap_each.to_a.first

    elsewhere = Brute::MessageTransport::OpenRouter.dump(wrapped, model: "openai/gpt-5")
    elsewhere[:reasoning].should == "step by step"
    elsewhere.key?(:reasoning_details).should.be.false
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
