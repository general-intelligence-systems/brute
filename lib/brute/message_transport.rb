# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  class MessageTransport

    # Convenience: Brute::MessageTransport.wrap_each(result) { |m| ... }
    def self.wrap_each(result, &block)
      new(result).wrap_each(&block)
    end

    #  Outbound: one Brute::Message in the library's format. Identity here.
    #
    # `model:` is what the turn is about to be sent to. A transport that puts
    # signed reasoning back on the wire needs it: a signature is only valid
    # against the provider that issued it, and the log outlives any one model.
    def self.dump(message, model: nil)
      message
    end

    # Outbound: the whole log in the library's format.
    def self.dump_all(messages, model: nil)
      messages.map { |message| dump(message, model: model) }
    end

    # Inbound: what the provider reported about this call, as a
    # Brute::UsageDetection::Usage. Each transport knows its own library's
    # response shape, so it is the one that knows which detector to ask.
    # Answers nil for a library that reports no usage at all.
    def self.usage_metrics(_result)
      nil
    end

    def initialize(result)
      @result = result
    end

    def wrap_each
      if block_given?
        messages.each { |message| yield wrap(message) }
      else
        # https://docs.ruby-lang.org/en/4.0/Object.html#method-i-enum_for
        enum_for(:wrap_each)
      end
    end

    # The result normalized to a flat list of the library's messages. A
    # single message, an array, or anything transcript-shaped (responds to
    # #messages).
    def messages
      if @result.is_a?(Array)
        @result.compact
      else
        if @result.respond_to?(:messages)
          @result.messages
        else
          [@result].compact
        end
      end
    end

    private

      # The Brute::Message view of a single library message. Identity here —
      # subclasses normalize their library's shape.
      def wrap(message)
        message
      end
  end
end

__END__

describe "brute/message_transport" do
  require "brute/messages"

  it "wraps a single message" do
    message = Brute::Message.new(role: :assistant, content: "hi")
    Brute::MessageTransport.new(message).wrap_each.to_a.should == [message]
  end

  it "wraps an array of messages" do
    a = Brute::Message.new(role: :assistant, content: "one")
    b = Brute::Message.new(role: :tool, content: "two", tool_call_id: "tc1")
    Brute::MessageTransport.new([a, b]).wrap_each.to_a.should == [a, b]
  end

  it "wraps a transcript-shaped object (responds to #messages)" do
    fake_chat = Class.new do
      attr_reader :messages
      def initialize(messages); @messages = messages; end
    end
    msgs = [Brute::Message.new(role: :user, content: "hi"),
            Brute::Message.new(role: :assistant, content: "hello")]

    Brute::MessageTransport.new(fake_chat.new(msgs)).wrap_each.to_a.map(&:role).should == [:user, :assistant]
  end

  it "yields each message to the block for the caller to append" do
    session = Brute.log
    session.user("hello")
    response = Brute::Message.new(role: :assistant, content: "hi there")

    Brute::MessageTransport.new(response).wrap_each { |message| session << message }

    session.last.role.should == :assistant
    session.last.content.should == "hi there"
  end

  it "exposes a class-level wrap_each convenience" do
    session = Brute.log
    a = Brute::Message.new(role: :assistant, content: "a")
    b = Brute::Message.new(role: :assistant, content: "b")

    Brute::MessageTransport.wrap_each([a, b]) { |message| session << message }

    session.map(&:content).should == ["a", "b"]
  end

  it "dump_all is the identity by default" do
    msgs = [Brute::Message.new(role: :user, content: "hi")]
    Brute::MessageTransport.dump_all(msgs).should == msgs
  end
end
