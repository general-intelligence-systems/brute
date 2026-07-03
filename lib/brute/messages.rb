# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # The in-memory conversation log is just a plain Array of RubyLLM::Message.
  # This module adds a little sugar for appending role-tagged messages; mix it
  # into an array via `Brute.log`. Persistence is NOT here — loading/saving the
  # log to disk is the Brute::Middleware::SessionLog middleware's job.
  module Messages
    def user(content);      self << ::RubyLLM::Message.new(role: :user,      content: content); end
    def assistant(content); self << ::RubyLLM::Message.new(role: :assistant, content: content); end
    def system(content);    self << ::RubyLLM::Message.new(role: :system,    content: content); end
  end

  # Build a fresh conversation log (an Array + Messages sugar), optionally
  # seeded with messages.
  #
  #   log = Brute.log
  #   log.user("hello")
  #   Brute.log(RubyLLM::Message.new(role: :user, content: "hi"))
  def self.log(*messages)
    [].extend(Messages).tap { |log| messages.flatten.each { |m| log << m } }
  end
end

__END__

describe "brute/messages" do
  it "appends role-tagged messages" do
    log = Brute.log
    log.user("hi")
    log.assistant("hello")
    log.map(&:role).should == [:user, :assistant]
    log.first.content.should == "hi"
  end

  it "seeds from given messages" do
    m = RubyLLM::Message.new(role: :user, content: "seed")
    Brute.log(m).should == [m]
  end

  it "is a plain Array (no special class)" do
    Brute.log.should.be.kind_of?(Array)
  end
end
