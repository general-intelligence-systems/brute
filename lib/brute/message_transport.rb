# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # Transports messages between an LLM library's format and Brute's format
  # (Brute::Message). This is the seam that keeps Brute framework-agnostic:
  # calling an LLM is trivial with any library, so Brute has no "completion
  # middleware" — the terminal `run` proc of an agent pipeline makes the LLM
  # call itself, and a MessageTransport translates at the boundary.
  #
  # Inbound (library response -> Brute), the transport wraps whatever the
  # proc got back and yields each message as a Brute::Message; the proc
  # appends:
  #
  #   response = client.complete(...)
  #   Brute::MessageTransport::RubyLLM.new(response).wrap_each do |message|
  #     env[:messages] << message
  #   end
  #
  # Outbound (Brute -> library), `dump_all` converts env[:messages] into the
  # shape the library's completion call expects:
  #
  #   client.complete(Brute::MessageTransport::RubyLLM.dump_all(env[:messages]), ...)
  #
  # This base class is the identity transport: it flattens the result into a
  # list of messages and yields them untouched. Library-specific subclasses
  # (see message_transport/*.rb) override #wrap and .dump. They reference
  # their library lazily, so requiring the library is your job — Brute
  # depends on none of them.
  class MessageTransport
    # Convenience: Brute::MessageTransport.wrap_each(result) { |m| ... }
    def self.wrap_each(result, &block)
      new(result).wrap_each(&block)
    end

    # Outbound: one Brute::Message in the library's format. Identity here.
    def self.dump(message)
      message
    end

    # Outbound: the whole log in the library's format.
    def self.dump_all(messages)
      messages.map { |message| dump(message) }
    end

    def initialize(result)
      @result = result
    end

    # Yield each result message as a Brute::Message. Without a block, returns
    # an Enumerator. The caller decides what to do with each (typically
    # append to env[:messages]).
    def wrap_each
      return enum_for(:wrap_each) unless block_given?

      messages.each { |message| yield wrap(message) }
    end

    # The result normalized to a flat list of the library's messages. A
    # single message, an array, or anything transcript-shaped (responds to
    # #messages).
    def messages
      case @result
      when Array then @result.compact
      else @result.respond_to?(:messages) ? @result.messages : [@result].compact
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
