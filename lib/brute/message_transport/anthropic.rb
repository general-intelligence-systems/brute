# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/message_transport"

module Brute
  class MessageTransport
    # MessageTransport for the official anthropic gem
    # (https://github.com/anthropics/anthropic-sdk-ruby). Brute does not
    # require it — you do:
    #
    #   require "anthropic"
    #
    #   client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
    #   response = client.messages.create(
    #     model:      "claude-opus-4-8",
    #     max_tokens: 16_000,
    #     system_:    Brute::MessageTransport::Anthropic.system_text(env[:messages]),
    #     messages:   Brute::MessageTransport::Anthropic.dump_all(env[:messages]),
    #     tools:      ...,
    #   )
    #   Brute::MessageTransport::Anthropic.wrap_each(response) { |m| env[:messages] << m }
    #
    # Anthropic's Messages API differs from chat-completions-shaped APIs in
    # two ways this transport absorbs: the system prompt is a top-level
    # parameter (not a message), and tool results are content blocks inside
    # a user message — consecutive tool results are folded into one user
    # turn so roles keep alternating.
    class Anthropic < MessageTransport
      # Whose signatures these are. OpenRouter names the same format when it
      # proxies Claude, so thinking that came back through it goes home.
      FORMAT = "anthropic-claude-v1"
      # The :system messages' text, for the top-level `system_:` parameter.
      def self.system_text(messages)
        messages.select { |m| m.role == :system }.map(&:content).join("\n\n")
      end

      # Brute log -> the `messages:` array. Drops :system messages (see
      # .system_text) and folds consecutive :tool results into one user turn.
      def self.dump_all(messages, model: nil)
        chat = messages.reject { |m| m.role == :system }

        chat.chunk_while { |a, b| a.role == :tool && b.role == :tool }.map do |group|
          if group.first.role == :tool
            { role: "user", content: group.map { |m| tool_result_block(m) } }
          else
            dump(group.first)
          end
        end
      end

      # Brute::Message -> an Anthropic message param hash.
      def self.dump(message, model: nil)
        case message.role
        when :tool
          { role: "user", content: [tool_result_block(message)] }
        when :assistant
          if message.tool_call?
            blocks = thinking_blocks(message)
            unless message.content.to_s.empty?
              blocks << { type: "text", text: message.content }
            end
            blocks += message.tool_calls.map { |tc| { type: "tool_use", id: tc.id, name: tc.name, input: tc.arguments } }
            { role: "assistant", content: blocks }
          else
            blocks = thinking_blocks(message)
            unless message.content.to_s.empty?
              blocks << { type: "text", text: message.content }
            end

            # Anthropic rejects an empty text block, so a message with nothing
            # left to send goes as plain content rather than an empty one.
            if blocks.empty?
              { role: "assistant", content: message.content }
            else
              { role: "assistant", content: blocks }
            end
          end
        else
          { role: message.role.to_s, content: message.content }
        end
      end

      # Thinking goes back first and unmodified. A signature Anthropic did
      # not issue cannot be verified -- a conversation replayed from another
      # provider carries thinking that is not Anthropic's -- and an
      # unverifiable block is a 400, so it sends none rather than a bad one.
      # Anthropic has two kinds of thinking block and no third: a summary is
      # a precis of thinking the provider would not show, and the signature
      # was issued over the thinking rather than the precis. Sent as a
      # thinking block it is a block that does not verify, so a sequence
      # carrying one is refused whole -- the same as a foreign format.
      def self.expressible?(reasoning)
        reasoning.blocks.all? { |block| block.type == :text || block.opaque? }
      end

      def self.thinking_blocks(message)
        if message.reasoning&.signed_by?(FORMAT) && expressible?(message.reasoning)
          message.reasoning.blocks.map do |block|
            if block.opaque?
              { type: "redacted_thinking", data: block.signature }
            else
              { type: "thinking", thinking: block.text.to_s, signature: block.signature }
            end
          end
        else
          []
        end
      end

      # A thinking block, or the redacted one that stands in for it when the
      # provider will not show its working. Both go back whole.
      def self.thinking_block(block)
        case block.type
        when :thinking
          Brute::Reasoning::Block.new(type: :text, text: block.thinking, signature: block.signature, format: FORMAT)
        when :redacted_thinking
          Brute::Reasoning::Block.new(type: :encrypted, signature: block.data, format: FORMAT)
        end
      end

      def self.tool_result_block(message)
        { type: "tool_result", tool_use_id: message.tool_call_id, content: message.content.to_s }
      end

      private

        # An Anthropic response (content blocks) -> one Brute::Message. Text
        # blocks join into the content; tool_use blocks become tool calls.
        def wrap(message)
          blocks = message.content

          text = blocks.select { |b| b.type == :text }.map(&:text).join

          # Thinking is its own block, its signature is what the API checks
          # when it comes back, and redacted thinking is a block whose payload
          # is not ours to read. All of them are kept, in order: what goes back
          # has to match what the model produced.
          thinking = blocks.filter_map { |b| self.class.thinking_block(b) }
          tool_calls = blocks.select { |b| b.type == :tool_use }.map do |b|
            if b.input.respond_to?(:to_h)
              arguments = b.input.to_h
            else
              arguments = b.input
            end
            Brute::ToolCall.new(id: b.id, name: b.name, arguments: arguments)
          end

          if tool_calls.empty?
            tool_calls = nil
          end

          Brute::Message.new(
            role:       :assistant,
            content:    text,
            tool_calls: tool_calls,
            reasoning:  Brute::Reasoning.build(blocks: thinking),
          )
        end
    end
  end
end

__END__

describe "brute/message_transport/anthropic" do
  require "brute/messages"

  # Duck-typed stand-ins for the anthropic gem's response objects so these
  # specs don't need the gem loaded.
  fake_text_block = Struct.new(:type, :text, keyword_init: true)
  fake_tool_block = Struct.new(:type, :id, :name, :input, keyword_init: true)
  fake_response   = Struct.new(:content, keyword_init: true)

  it "extracts the system prompt" do
    log = Brute.log
    log.system("be helpful")
    log.user("hi")
    Brute::MessageTransport::Anthropic.system_text(log).should == "be helpful"
  end

  it "dumps tool calls as tool_use blocks" do
    m = Brute::Message.new(role: :assistant, content: "thinking...",
                           tool_calls: [{ id: "tc1", name: "shell", arguments: { "command" => "ls" } }])
    dumped = Brute::MessageTransport::Anthropic.dump(m)
    dumped[:content].last.should == { type: "tool_use", id: "tc1", name: "shell", input: { "command" => "ls" } }
  end

  it "folds consecutive tool results into one user turn" do
    log = Brute.log
    log.user("go")
    log.tool("a", tool_call_id: "tc1")
    log.tool("b", tool_call_id: "tc2")

    dumped = Brute::MessageTransport::Anthropic.dump_all(log)
    dumped.size.should == 2
    dumped.last[:role].should == "user"
    dumped.last[:content].map { |b| b[:tool_use_id] }.should == %w[tc1 tc2]
  end

  it "sends signed thinking back first, ahead of the text" do
    # The sequence is part of what is verified, so thinking leads.
    m = Brute::Message.new(role: :assistant, content: "done", reasoning: {
      blocks: [{ type: :text, text: "let me think", signature: "sig-1", format: "anthropic-claude-v1" }],
    })

    Brute::MessageTransport::Anthropic.dump(m)[:content].should == [
      { type: "thinking", thinking: "let me think", signature: "sig-1" },
      { type: "text", text: "done" },
    ]
  end

  it "sends an opaque payload home as redacted_thinking, under either name" do
    # Anthropic calls it redacted_thinking; OpenRouter calls the same Claude
    # payload reasoning.encrypted. A conversation logged through either one
    # goes back the same way.
    [:redacted, :encrypted].each do |type|
      m = Brute::Message.new(role: :assistant, content: "done", reasoning: {
        blocks: [{ type: type, signature: "blob", format: "anthropic-claude-v1" }],
      })

      Brute::MessageTransport::Anthropic.dump(m)[:content].first
        .should == { type: "redacted_thinking", data: "blob" }
    end
  end

  it "sends no thinking at all rather than a block it cannot vouch for" do
    # An unverifiable block is a 400, and no thinking beats a failed request:
    # a signature Anthropic did not issue, and a block carrying none where it
    # requires one, are both refused -- and refused whole.
    foreign = Brute::Message.new(role: :assistant, content: "done", reasoning: {
      blocks: [{ type: :text, text: "thought", signature: "sig-1", format: "openai-responses-v1" }],
    })

    partly_signed = Brute::Message.new(role: :assistant, content: "done", reasoning: {
      blocks: [
        { type: :text, text: "step one", signature: "sig-1", format: "anthropic-claude-v1" },
        { type: :text, text: "step two",                     format: "anthropic-claude-v1" },
      ],
    })

    [foreign, partly_signed].each do |m|
      Brute::MessageTransport::Anthropic.dump(m)[:content].should == [{ type: "text", text: "done" }]
    end
  end

  it "wraps text and tool_use blocks into one assistant message" do
    response = fake_response.new(content: [
      fake_text_block.new(type: :text, text: "running ls"),
      fake_tool_block.new(type: :tool_use, id: "tc1", name: "shell", input: { "command" => "ls" }),
    ])

    out = Brute::MessageTransport::Anthropic.new(response).wrap_each.to_a.first
    out.content.should == "running ls"
    out.tool_calls.first.name.should == "shell"
  end
end
