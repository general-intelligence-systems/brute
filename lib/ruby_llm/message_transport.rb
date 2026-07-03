# frozen_string_literal: true

require "bundler/setup"
require "brute"

module RubyLLM
  # Transports the result of an LLM call into Brute's message format.
  #
  # Calling an LLM is trivial — `RubyLLM.chat.ask "..."` — so Brute has no
  # "completion middleware". The terminal `run` of an agent pipeline is an
  # inline proc that makes the LLM call itself. The only wrinkle: RubyLLM hands
  # back its own objects (a Message, an array, a whole Chat transcript), while
  # the rest of the stack — the turn manager, event handlers, tool loop and
  # SessionLog persistence — works off `env[:messages]` (a plain message log;
  # see Brute.log).
  #
  # This makes NO LLM call and does NO appending. It just wraps what the proc
  # got back and yields each message in Brute's format; the proc appends:
  #
  #   response = provider.complete(env[:messages], ...)          # one Message
  #   RubyLLM::MessageTransport.new(response).wrap_each do |message|
  #     env[:messages] << message
  #   end
  #
  #   before = chat.messages.length                              # a Chat loop
  #   chat.complete
  #   RubyLLM::MessageTransport.new(chat.messages[before..]).wrap_each do |message|
  #     env[:messages] << message
  #   end
  class MessageTransport
    # Convenience: RubyLLM::MessageTransport.wrap_each(result) { |m| ... }
    def self.wrap_each(result, &block)
      new(result).wrap_each(&block)
    end

    def initialize(result)
      @result = result
    end

    # Yield each result message in Brute's format. Without a block, returns an
    # Enumerator. The caller decides what to do with each (typically append to
    # env[:messages]).
    def wrap_each
      return enum_for(:wrap_each) unless block_given?

      messages.each { |message| yield wrap(message) }
    end

    # The result normalized to a flat list of messages. A single Message, an
    # array, or anything transcript-shaped (a Chat responds to #messages).
    def messages
      case @result
      when ::RubyLLM::Message then [@result]
      when Array              then @result.compact
      else @result.respond_to?(:messages) ? @result.messages : Array(@result)
      end
    end

    private

      # The Brute-format view of a single message. RubyLLM::Message already IS
      # Brute's message format, so this is the identity seam — the place to
      # normalize if the two formats ever diverge.
      def wrap(message)
        message
      end
  end
end

__END__

describe "ruby_llm/message_transport" do
  require "brute/messages"

  it "wraps a single message" do
    message = RubyLLM::Message.new(role: :assistant, content: "hi")
    RubyLLM::MessageTransport.new(message).wrap_each.to_a.should == [message]
  end

  it "wraps an array of messages" do
    a = RubyLLM::Message.new(role: :assistant, content: "one")
    b = RubyLLM::Message.new(role: :tool, content: "two", tool_call_id: "tc1")
    RubyLLM::MessageTransport.new([a, b]).wrap_each.to_a.should == [a, b]
  end

  it "wraps a transcript-shaped object (a Chat)" do
    fake_chat = Class.new do
      attr_reader :messages
      def initialize(messages); @messages = messages; end
    end
    msgs = [RubyLLM::Message.new(role: :user, content: "hi"),
            RubyLLM::Message.new(role: :assistant, content: "hello")]

    RubyLLM::MessageTransport.new(fake_chat.new(msgs)).wrap_each.to_a.map(&:role).should == [:user, :assistant]
  end

  it "yields each message to the block for the caller to append" do
    session = Brute.log
    session.user("hello")
    response = RubyLLM::Message.new(role: :assistant, content: "hi there")

    RubyLLM::MessageTransport.new(response).wrap_each { |message| session << message }

    session.last.role.should == :assistant
    session.last.content.should == "hi there"
  end

  it "exposes a class-level wrap_each convenience" do
    session = Brute.log
    a = RubyLLM::Message.new(role: :assistant, content: "a")
    b = RubyLLM::Message.new(role: :assistant, content: "b")

    RubyLLM::MessageTransport.wrap_each([a, b]) { |message| session << message }

    session.map(&:content).should == ["a", "b"]
  end
end
