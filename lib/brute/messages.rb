# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # One tool invocation requested by the model. Arguments are always a Hash.
  ToolCall = Data.define(:id, :name, :arguments) do
    def initialize(id:, name:, arguments: {})
      super(id: id, name: name.to_s, arguments: arguments.to_h)
    end
  end

  # Brute's canonical, framework-agnostic message. The rest of the stack
  # (middleware, tool loop, persistence) never calls anything beyond
  # #role, #content, #tool_calls, #tool_call_id and #to_h — so any object
  # that duck-types those methods can ride in env[:messages] too. This Data
  # class is simply the canonical implementation.
  #
  #   Brute::Message.new(role: :user, content: "hi")
  #   Brute::Message.new(role: :assistant, content: "", tool_calls: [
  #     Brute::ToolCall.new(id: "tc1", name: "shell", arguments: { "command" => "ls" }),
  #   ])
  #   Brute::Message.new(role: :tool, content: "result", tool_call_id: "tc1")
  Message = Data.define(:role, :content, :tool_calls, :tool_call_id) do
    def initialize(role:, content: nil, tool_calls: nil, tool_call_id: nil)
      formatted_calls = tool_calls&.map do |tc|
        tc.is_a?(ToolCall) ? tc : ToolCall.new(**tc.to_h.transform_keys(&:to_sym))
      end
  
      super(
        role: role.to_sym,
        content: content,
        tool_calls: formatted_calls,
        tool_call_id: tool_call_id
      )
    end
  
    def tool_call? = !tool_calls.nil? && !tool_calls.empty?
    alias_method :has_tool_calls?, :tool_call?
  
    # Clean, JSON-ready hash export dropping nil values
    def to_h(...)
      hash = super
      hash[:tool_calls] = tool_calls.map(&:to_h) if tool_calls
      hash.compact
    end
  end

  # The in-memory conversation log is just a plain Array of Brute::Message.
  # This module adds a little sugar for appending role-tagged messages; mix it
  # into an array via `Brute.log`. Persistence is NOT here — loading/saving the
  # log to disk is the Brute::Middleware::SessionLog middleware's job.
  module Messages
    def user(content);      self << Message.new(role: :user,      content: content); end
    def assistant(content); self << Message.new(role: :assistant, content: content); end
    def system(content);    self << Message.new(role: :system,    content: content); end

    def tool(content, tool_call_id:)
      self << Message.new(role: :tool, content: content, tool_call_id: tool_call_id)
    end
  end

  # Build a fresh conversation log (an Array + Messages sugar), optionally
  # seeded with messages.
  #
  #   log = Brute.log
  #   log.user("hello")
  #   Brute.log(Brute::Message.new(role: :user, content: "hi"))
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

  it "appends tool results" do
    log = Brute.log
    log.tool("result", tool_call_id: "tc1")
    log.last.role.should == :tool
    log.last.tool_call_id.should == "tc1"
  end

  it "seeds from given messages" do
    m = Brute::Message.new(role: :user, content: "seed")
    Brute.log(m).should == [m]
  end

  it "is a plain Array (no special class)" do
    Brute.log.should.be.kind_of?(Array)
  end

  it "symbolizes string roles" do
    Brute::Message.new(role: "user", content: "hi").role.should == :user
  end

  it "coerces tool_calls hashes into ToolCall" do
    m = Brute::Message.new(
      role: :assistant, content: "",
      tool_calls: [{ "id" => "tc1", "name" => "shell", "arguments" => { "command" => "ls" } }]
    )
    m.tool_calls.first.name.should == "shell"
    m.tool_calls.first.arguments.should == { "command" => "ls" }
    m.tool_call?.should.be.true
  end

  it "round-trips through to_h" do
    m = Brute::Message.new(role: :assistant, content: "",
                           tool_calls: [{ id: "tc1", name: "shell", arguments: {} }])
    Brute::Message.new(**m.to_h).should == m
  end

  it "to_h drops nil fields" do
    Brute::Message.new(role: :user, content: "hi").to_h.should == { role: :user, content: "hi" }
  end
end
