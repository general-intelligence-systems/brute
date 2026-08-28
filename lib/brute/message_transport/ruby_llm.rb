# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"

module Brute
  class MessageTransport
    # MessageTransport for the ruby_llm gem (https://github.com/crmne/ruby_llm).
    # Brute does not require it — you do:
    #
    #   require "ruby_llm"
    #
    # The gem changed shape at 2.0, and it changed in exactly the place that
    # decides what this transport can promise. Through 1.x a message models
    # its reasoning as a RubyLLM::Thinking: one text, one signature, and
    # nowhere to put a sequence -- so a sequence cannot come back out of it
    # the way it went in. 2.0 adds #raw_reasoning, which holds the whole
    # reasoning_details sequence and which the provider adapters send on, so
    # every entry goes back with the type, payload and signature it had. The
    # model id moved too: #model_id in 1.x, #model in 2.0.
    #
    # Two shapes, so two subclasses, and .for is the only place that asks
    # which one is installed. Nothing else branches on a version.
    class RubyLLM < MessageTransport
      # The release that added somewhere for a whole sequence to live.
      VERBATIM = Gem::Version.new("2.0")

      # Which subclass the bundled gem calls for. Read lazily: brute does not
      # require ruby_llm, so ::RubyLLM only exists once the caller has.
      def self.for(version = ::RubyLLM::VERSION)
        if Gem::Version.new(version) >= VERBATIM
          V2
        else
          V1
        end
      end

      # Brute::MessageTransport::RubyLLM.new(response) answers whichever
      # subclass fits; asking a subclass for one builds it as usual.
      def self.new(result)
        if self == RubyLLM
          self.for.new(result)
        else
          super
        end
      end

      # Dispatchers. Both subclasses override these.
      def self.dump(message, model: nil) = self.for.dump(message, model: model)

      def self.thinking(message) = self.for.thinking(message)

      # What the provider reported about this call — the transport knows its
      # own library's shape, so it knows which detector to ask.
      def self.usage_metrics(message)
        Brute::UsageDetection::RubyLLM.detect(message)
      end

      # ruby_llm keys tool calls by id; brute keeps a flat list.
      def self.tool_calls(message)
        message.tool_calls&.to_h do |tc|
          [ tc.id, ::RubyLLM::ToolCall.new(id: tc.id, name: tc.name, arguments: tc.arguments) ]
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
            Brute::ToolCall.new(id: tc.id, name: tc.name, arguments: tc.arguments)
          end

          Brute::Message.new(
            role:         message.role,
            content:      message.content&.to_s, # Preserves nil safely
            tool_calls:   tool_calls,
            tool_call_id: message.tool_call_id,
            reasoning:    reasoning(message),
          )
        end

        # The thinking ruby_llm flattened: one text and one signature, which
        # is all 1.x ever has, and all 2.0 has when the provider adapter
        # kept no reasoning_details of its own.
        def flattened(message)
          if message.respond_to?(:thinking) && message.thinking
            Brute::Reasoning.build(
              text:      message.thinking.text,
              signature: message.thinking.signature,
              format:    answering_model(message),
            )
          end
        end
    end

    # ruby_llm 1.x. A message carries RubyLLM::Thinking and nothing else, so
    # a sequence of more than one block has nowhere to live: it would go back
    # as one block holding the joined text and the first signature, which is
    # a modified sequence and a 400. Nothing goes instead.
    class RubyLLM::V1 < RubyLLM
      def self.dump(message, model: nil)
        ::RubyLLM::Message.new(
          role:         message.role,
          content:      message.content,
          tool_calls:   tool_calls(message),
          tool_call_id: message.tool_call_id,
          thinking:     thinking(message),
        )
      end

      # One block or none. RubyLLM::Thinking.build answers nil when there is
      # nothing to say; empty text is passed as nil rather than "" so an
      # encrypted payload renders as redacted_thinking rather than as a
      # thinking block with an empty body.
      def self.thinking(message)
        reasoning = message.reasoning

        if reasoning&.blocks&.one?
          block = reasoning.blocks.first

          ::RubyLLM::Thinking.build(
            text:      block.text.to_s.empty? ? nil : block.text,
            signature: block.signature,
          )
        end
      end

      private

        # 1.x names it #model_id.
        def answering_model(message)
          if message.respond_to?(:model_id)
            message.model_id
          end
        end

        def reasoning(message) = flattened(message)
    end

    # ruby_llm 2.0 and later. #raw_reasoning holds the reasoning_details
    # sequence and the provider adapters send it on, so a sequence goes home
    # entry for entry. Where the adapter kept none there is still #thinking,
    # which carries one text and one signature.
    class RubyLLM::V2 < RubyLLM
      def self.dump(message, model: nil)
        ::RubyLLM::Message.new(
          role:          message.role,
          content:       message.content,
          tool_calls:    tool_calls(message),
          tool_call_id:  message.tool_call_id,
          thinking:      thinking(message),
          raw_reasoning: raw_reasoning(message),
        )
      end

      # 2.0 hands #raw_reasoning to the provider as the reasoning_details
      # array, so the stored sequence goes out in that shape: each block
      # under the type that names it, and its payload under the key that
      # type gives it. Prose that was only ever prose has no sequence to
      # make of itself, and travels on #thinking instead.
      def self.raw_reasoning(message)
        reasoning = message.reasoning

        if reasoning&.detailed?
          reasoning.blocks.map { |block| detail(block) }
        end
      end

      # One stored block as a reasoning detail. Reasoning text carries
      # `text` and the `signature` that verifies it, a summary carries
      # `summary`, and an encrypted item carries `data` -- written under the
      # wrong key the payload is simply lost.
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

      # The readable view. #raw_reasoning is what actually goes back out;
      # this is what a human sees, and what a provider adapter that kept no
      # payload falls back on.
      def self.thinking(message)
        reasoning = message.reasoning

        if reasoning
          ::RubyLLM::Thinking.build(
            text:      reasoning.text.empty? ? nil : reasoning.text,
            signature: reasoning.blocks.find(&:signed?)&.signature,
          )
        end
      end

      private

        # 2.0 names it #model.
        def answering_model(message)
          if message.respond_to?(:model)
            message.model
          end
        end

        # The reasoning_details sequence where the adapter kept one, and
        # ruby_llm's flattened view where it did not.
        def reasoning(message)
          details = []
          if message.respond_to?(:raw_reasoning)
            details = Array(message.raw_reasoning)
          end

          if details.empty?
            flattened(message)
          else
            Brute::Reasoning.build(blocks: details.map { |detail| block(detail) })
          end
        end

        # One reasoning detail as a stored block. The type names which key
        # the payload arrived under.
        def block(detail)
          hash = detail.to_h.transform_keys(&:to_sym)
          type = hash[:type].to_s.split(".").last.to_s

          Brute::ReasoningBlock.new(
            type:      type.empty? ? :text : type.to_sym,
            text:      hash[:text] || hash[:summary],
            signature: hash[:signature] || hash[:data],
            format:    hash[:format],
            id:        hash[:id],
            index:     hash[:index],

          )
        end
    end
  end
end

__END__

describe "brute/message_transport/ruby_llm" do
  require "brute/messages"
  require "ruby_llm"

  # Duck-typed stand-ins for RubyLLM::Message / RubyLLM::ToolCall so these
  # specs don't need a particular version of the gem loaded. The 2.0 shape is
  # not installable alongside the 1.x one, so it is stood in for.
  fake_tool_call = Struct.new(:id, :name, :arguments, keyword_init: true)
  fake_message   = Struct.new(:role, :content, :tool_calls, :tool_call_id, keyword_init: true)
  fake_thinking  = Struct.new(:text, :signature, keyword_init: true)

  it "picks the subclass its bundled gem calls for" do
    # 1.x models thinking as one text and one signature; 2.0 keeps the
    # whole reasoning_details sequence. Two shapes, two subclasses.
    Brute::MessageTransport::RubyLLM.for("1.14.1").should == Brute::MessageTransport::RubyLLM::V1
    Brute::MessageTransport::RubyLLM.for("1.16.0").should == Brute::MessageTransport::RubyLLM::V1
    Brute::MessageTransport::RubyLLM.for("2.0.0").should  == Brute::MessageTransport::RubyLLM::V2
    Brute::MessageTransport::RubyLLM.for("2.4.0").should  == Brute::MessageTransport::RubyLLM::V2
  end

  it "builds the subclass, not the dispatcher" do
    m = fake_message.new(role: :assistant, content: "hi")
    Brute::MessageTransport::RubyLLM.new(m).should.be.kind_of?(Brute::MessageTransport::RubyLLM)
    Brute::MessageTransport::RubyLLM::V1.new(m).should.be.kind_of?(Brute::MessageTransport::RubyLLM::V1)
  end

  it "wraps a plain assistant message" do
    m = fake_message.new(role: :assistant, content: "hi")
    out = Brute::MessageTransport::RubyLLM::V1.new(m).wrap_each.to_a
    out.first.should.be.kind_of?(Brute::Message)
    out.first.content.should == "hi"
  end

  it "wraps ruby_llm's id-keyed tool_calls hash into a flat list" do
    tc = fake_tool_call.new(id: "tc1", name: "shell", arguments: { "command" => "ls" })
    m = fake_message.new(role: :assistant, content: "", tool_calls: { "tc1" => tc })

    out = Brute::MessageTransport::RubyLLM::V1.new(m).wrap_each.to_a.first
    out.tool_calls.first.should == Brute::ToolCall.new(id: "tc1", name: "shell", arguments: { "command" => "ls" })
  end

  it "stamps the model that answered, under the name 1.x gives it" do
    # RubyLLM::Message names it #model_id through 1.x -- there is no #model,
    # so asking for one stamped nothing and the signature went out
    # unattributed.
    m = fake_message.new(role: :assistant, content: "done")
    m.define_singleton_method(:thinking) { fake_thinking.new(text: "thought", signature: "sig-1") }
    m.define_singleton_method(:model_id) { "claude-sonnet-4" }

    block = Brute::MessageTransport::RubyLLM::V1.new(m).wrap_each.to_a.first.reasoning.blocks.first
    block.signature.should == "sig-1"
    block.format.should == "claude-sonnet-4"
  end

  it "sends one block back with the signature it carried" do
    m = Brute::Message.new(role: :assistant, content: "done", reasoning: {
      blocks: [{ type: :text, text: "thought it through", signature: "sig-1" }],
    })

    thinking = Brute::MessageTransport::RubyLLM::V1.dump(m).thinking
    thinking.text.should == "thought it through"
    thinking.signature.should == "sig-1"
  end

  it "sends nothing rather than a sequence 1.x cannot hold" do
    # RubyLLM::Thinking has room for one text and one signature. A sequence
    # put through it comes out as the joined text under the first block's
    # signature, which is a modified sequence -- a 400, not a near miss. So
    # it does not go.
    m = Brute::Message.new(role: :assistant, content: "done", reasoning: {
      blocks: [
        { type: :text, text: "step one", signature: "sig-1", format: "anthropic-claude-v1" },
        { type: :text, text: "step two", signature: "sig-2", format: "anthropic-claude-v1" },
      ],
    })

    Brute::MessageTransport::RubyLLM::V1.dump(m).thinking.should.be.nil
  end

  it "hands an encrypted payload over as a payload, not as empty thinking" do
    # An encrypted block has no prose. Passed as "" rather than nil it renders
    # as a thinking block with an empty body; passed as nil ruby_llm renders
    # the redacted_thinking block the payload actually belongs in.
    m = Brute::Message.new(role: :assistant, content: "done", reasoning: {
      blocks: [{ type: :encrypted, signature: "b64blob", format: "anthropic-claude-v1" }],
    })

    thinking = Brute::MessageTransport::RubyLLM::V1.dump(m).thinking
    thinking.text.should.be.nil
    thinking.signature.should == "b64blob"
  end

  it "round-trips a reasoning_details sequence, entry for entry" do
    # 2.0 hands #raw_reasoning on to the provider, so each entry goes back
    # under the type that named it with the payload that type gives it.
    details = [
      { "type" => "reasoning.text", "text" => "step one", "signature" => "sig-1",
        "format" => "anthropic-claude-v1", "index" => 0 },
      { "type" => "reasoning.encrypted", "data" => "b64blob",
        "format" => "anthropic-claude-v1", "index" => 1 },
    ]

    m = fake_message.new(role: :assistant, content: "done")
    m.define_singleton_method(:raw_reasoning) { details }

    wrapped = Brute::MessageTransport::RubyLLM::V2.new(m).wrap_each.to_a.first

    wrapped.reasoning.text.should == "step one"
    wrapped.reasoning.blocks.map(&:type).should == [:text, :encrypted]

    # ...and back out in the shape it came in, entry for entry.
    Brute::MessageTransport::RubyLLM::V2.raw_reasoning(wrapped).should == [
      { type: "reasoning.text", format: "anthropic-claude-v1", index: 0,
        text: "step one", signature: "sig-1" },
      { type: "reasoning.encrypted", format: "anthropic-claude-v1", index: 1,
        data: "b64blob" },
    ]
  end

  it "makes no details sequence out of prose that was only ever prose" do
    # A sequence brute invented is not one the model produced, so plaintext
    # travels as plaintext -- on #thinking, where a reader finds it -- and no
    # reasoning_details array is built around it.
    plain = Brute::Message.new(role: :assistant, content: "done", reasoning: "just thinking")

    Brute::MessageTransport::RubyLLM::V2.raw_reasoning(plain).should.be.nil
    Brute::MessageTransport::RubyLLM::V2.dump(plain).thinking.text.should == "just thinking"
  end

  it "falls back to the flattened view when the adapter kept no details" do
    # Not every 2.0 provider adapter keeps a reasoning_details array of its
    # own. Where none was kept there is still #thinking, and 2.0 names the
    # model #model where 1.x named it #model_id.
    m = fake_message.new(role: :assistant, content: "done")
    m.define_singleton_method(:thinking) { fake_thinking.new(text: "thought", signature: "sig-1") }
    m.define_singleton_method(:model) { "anthropic/claude-sonnet-4" }
    m.define_singleton_method(:raw_reasoning) { nil }

    reasoning = Brute::MessageTransport::RubyLLM::V2.new(m).wrap_each.to_a.first.reasoning
    reasoning.text.should == "thought"
    reasoning.blocks.first.format.should == "anthropic/claude-sonnet-4"
  end
end
