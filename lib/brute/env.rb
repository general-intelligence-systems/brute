# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # What the turn came back with, asked of the env itself.
  #
  #   env = agent.start("hello")
  #   env.extend(Brute::Env)
  #   env.reply.content if env.has_reply?
  #
  # A turn ends with whatever the last middleware left in env[:messages], and
  # that is not always an answer: a turn that only ran tools, or that the
  # provider failed, ends on something else. So the reply is the last message
  # AND only when the assistant is the one who wrote it.
  module Env
    def has_reply?
      !reply.nil?
    end

    def reply
      messages = self[:messages]

      if messages.respond_to?(:last) && messages.last&.role == :assistant
        messages.last
      end
    end
  end
end

__END__

require "brute/messages"

describe "brute/env" do
  it "answers whether the turn produced a reply, and what it was" do
    env = { messages: Brute.log }.extend(Brute::Env)

    env.has_reply?.should.be.false

    env[:messages].user("hello")
    env.has_reply?.should.be.false

    env[:messages].assistant("hi back")
    env.has_reply?.should.be.true
    env.reply.content.should == "hi back"

    env[:messages] << Brute::Message.new(role: :tool, content: "ran", tool_call_id: "tc1")
    env.has_reply?.should.be.false

    {}.extend(Brute::Env).has_reply?.should.be.false
  end
end
