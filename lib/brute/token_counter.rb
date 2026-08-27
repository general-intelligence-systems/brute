# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"

module Brute
  # How big a conversation is, in tokens.
  #
  # A counter is anything answering `count(messages, tools: nil)`. The tools
  # are part of the question because their schemas ride in every request
  # alongside the messages -- an agent carrying a dozen of them is spending
  # context on JSON Schema before anyone has said a word.
  #
  #   counter = Brute::TokenCounter::Approximate.new
  #   counter.count(env[:messages], tools: env[:tools])
  #
  # What a turn is *currently* costing is a different question, and
  # `estimate` answers it: the provider counted the conversation exactly when
  # it answered, so that number is trusted and only what has been appended
  # since is counted locally.
  #
  #   Brute::TokenCounter.estimate(env)
  #
  module TokenCounter
    def self.default = Approximate.new

    # What the whole turn costs right now.
    #
    # :counter defaults to the one the turn already decided on
    # (env[:token_counter]), :tools to the ones the pipeline advertises
    # (env[:tools]).
    #
    # The reported total already covers the system prompt, the tool schemas
    # and the provider's own chat-template overhead, so the warm path adds
    # only the messages that landed after the reply it describes -- and never
    # the schemas, which are already inside it. Anything else double counts.
    def self.estimate(env, counter: nil, tools: nil)
      counter ||= env[:token_counter] || default
      if tools.nil?
        tools = env[:tools]
      end
      messages = env[:messages] || []
      reported = env.dig(:metadata, :last_llm_usage)&.total.to_i
      answered = messages.rindex { |message| message.role == :assistant }

      # Nothing sent yet, or a conversation the reported number no longer
      # describes -- a compaction that left no reply behind, say. Count it all.
      if reported.zero? || answered.nil?
        counter.count(messages, tools: tools)
      else
        reported + counter.count(messages[(answered + 1)..])
      end
    end

    # The text a counter measures.
    #
    # One rendering, so two counters cannot disagree about what the
    # conversation even is -- and it is the same text a summariser reads,
    # which is why it says who spoke and what was called rather than being
    # the shortest thing that could be measured.
    module Rendering
      def self.conversation(messages) = Array(messages).map { |message| message(message) }.join("\n")

      def self.message(message)
        parts = ["#{message.role}:", message.content.to_s]

        message.tool_calls&.each do |call|
          parts << "#{call.name}(#{JSON.generate(call.arguments)}) -> #{call.id}"
        end

        unless message.tool_call_id.nil?
          parts << "(answering #{message.tool_call_id})"
        end

        parts.reject(&:empty?).join(" ")
      end

      # The schemas as the provider is given them, which is what they cost.
      def self.tools(tools)
        wrapped = Brute::Tools::Adapter.wrap_all(tools || [])

        if wrapped.empty?
          ""
        else
          JSON.generate(wrapped.values.map(&:to_h))
        end
      end
    end
  end
end

__END__

describe "brute/token_counter" do
  def usage(total) = Brute::UsageDetection::Usage.new(total: total)

  it "measures a conversation and its schemas, and trusts the provider for what it already counted" do
    log = Brute.log
    log.system("you are a helpful agent")
    log.user("what changed?")

    counter = Brute::TokenCounter.default
    counter.should.be.kind_of Brute::TokenCounter::Approximate

    text = Brute::TokenCounter::Rendering.conversation(log)
    text.should == "system: you are a helpful agent\nuser: what changed?"

    # A tool call and the result answering it are rendered too -- both cost
    # tokens, and neither is in the message's content.
    log << Brute::Message.new(
      role: :assistant,
      content: "",
      tool_calls: [{ id: "tc1", name: "search", arguments: { "query" => "fed" } }]
    )
    log.tool("found nothing", tool_call_id: "tc1")
    Brute::TokenCounter::Rendering.conversation(log).should.include 'search({"query":"fed"}) -> tc1'
    Brute::TokenCounter::Rendering.conversation(log).should.include "(answering tc1)"

    # Schemas ride in every request, so they are part of the question.
    tool = Brute::Turn::ToolPipeline.new(name: "search", description: "search the web") do
      run ->(env) { env[:result] = "" }
    end
    Brute::TokenCounter::Rendering.tools(nil).should == ""
    Brute::TokenCounter::Rendering.tools([tool]).should.include "search the web"
    counter.count(log, tools: [tool]).should > counter.count(log)

    # Nothing reported yet: everything is counted, schemas included.
    cold = { messages: log, tools: [tool], metadata: {} }
    Brute::TokenCounter.estimate(cold).should == counter.count(log, tools: [tool])

    # Reported: the provider's number, plus only what landed after the reply
    # it describes. The schemas are already inside it.
    log.assistant("nothing changed")
    log.user("are you sure?")
    warm = { messages: log, tools: [tool], metadata: { last_llm_usage: usage(9_000) } }
    Brute::TokenCounter.estimate(warm).should == 9_000 + counter.count([log.last])

    # A conversation the reported number no longer describes -- a compaction
    # that left no reply behind -- is counted from scratch rather than added
    # to a total for a conversation that is gone.
    stale = { messages: Brute.log.tap { |l| l.user("only me") }, metadata: { last_llm_usage: usage(9_000) } }
    Brute::TokenCounter.estimate(stale).should == counter.count(stale[:messages])

    # The counter the turn already decided on is the one that gets used.
    given = { messages: log, metadata: {}, token_counter: Object.new }
    given[:token_counter].define_singleton_method(:count) { |_messages, tools: nil| 7 }
    Brute::TokenCounter.estimate(given).should == 7
  end
end
