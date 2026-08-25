# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"

module Brute
  module Compaction
    # The shapes a compaction strategy selects over.
    #
    # A transcript is an Array of Brute::Message, but what may be given up is
    # never a single message. An assistant's tool calls travel with the results
    # that answer them, and a user's question with everything said before the
    # next one -- a provider rejects the halves. So a strategy works in groups:
    # a *step* is an assistant message and the tool results immediately after
    # it, a *turn* is a real user message and everything up to the next.
    #
    # A message a strategy produced carries its name at the head of its content,
    # because Brute::Message has nowhere else to put it. That is what stops a
    # later pass from summarising a summary.
    module Transcript
      MARK = /\A\[compacted:([a-z_]+)\]/

      def self.mark(strategy, text) = "[compacted:#{strategy}] #{text}"

      def self.marked?(message, strategy = nil)
        name = message.content.to_s[MARK, 1]

        if strategy.nil?
          !name.nil?
        else
          name == strategy.to_s
        end
      end

      # Roughly what a slice costs, for code holding messages rather than an
      # env. A strategy weighs with the turn's own counter instead -- see
      # Brute::Compaction.counter.
      def self.tokens(messages) = Brute::TokenCounter.default.count(messages)

      def self.at(messages, indices) = indices.map { |index| messages[index] }

      # The transcript as plain text, for a summariser to read. Rendering it
      # rather than replaying the messages keeps a half tool exchange -- a call
      # whose result was left behind, a result whose call was -- off the wire,
      # which is a shape providers refuse.
      #
      # It is the same text the counters measure, so what a summariser is
      # asked to shrink and what the trigger weighed are one thing.
      def self.render(messages) = Brute::TokenCounter::Rendering.conversation(messages)

      def self.line(message) = Brute::TokenCounter::Rendering.message(message)

      # Where the leading system block ends. Nothing above this is ever given up.
      def self.system_end(messages)
        messages.index { |message| message.role != :system } || messages.length
      end

      # The user message the current task hangs off, ignoring whatever an
      # earlier compaction left behind.
      def self.task_index(messages)
        messages.rindex { |message| message.role == :user && !marked?(message) }
      end

      # Where the current task's steps begin: after its anchor, or after the
      # instructions when the conversation has no anchor at all.
      def self.step_start(messages)
        task = task_index(messages)

        if task.nil?
          system_end(messages)
        else
          task + 1
        end
      end

      # An assistant message and every tool result answering it, as index ranges.
      def self.steps(messages, from:)
        [].tap do |spans|
          index = from

          while index < messages.length
            if messages[index].role == :assistant
              finish = index + 1

              while finish < messages.length && messages[finish].role == :tool
                finish += 1
              end

              spans << (index...finish)
              index = finish
            else
              index += 1
            end
          end
        end
      end

      # A real user message and everything up to the next one, as index ranges.
      def self.turns(messages, from:, to:)
        starts = (from...to).select do |index|
          messages[index].role == :user && !marked?(messages[index])
        end

        starts.each_with_index.map do |start, position|
          start...(starts[position + 1] || to)
        end
      end
    end
  end
end

__END__
describe "brute/compaction/transcript" do
  def message(role, content, tool_calls: nil, tool_call_id: nil)
    Brute::Message.new(role: role, content: content, tool_calls: tool_calls, tool_call_id: tool_call_id)
  end

  it "marks its own work, and groups a transcript into steps and turns" do
    call = { id: "tc1", name: "shell", arguments: { "command" => "ls" } }

    messages = [
      message(:system, "instructions"),
      message(:system, "more instructions"),
      message(:user, "first question"),
      message(:assistant, "an answer"),
      message(:user, "second question"),
      message(:assistant, "", tool_calls: [call]),
      message(:tool, "the result", tool_call_id: "tc1"),
      message(:assistant, "done"),
    ]

    Brute::Compaction::Transcript.system_end(messages).should == 2
    Brute::Compaction::Transcript.task_index(messages).should == 4
    Brute::Compaction::Transcript.step_start(messages).should == 5

    # A step holds the assistant message together with the results answering it.
    Brute::Compaction::Transcript.steps(messages, from: 5).map(&:to_a).should == [[5, 6], [7]]

    # A turn runs from one real user message to the next.
    Brute::Compaction::Transcript.turns(messages, from: 2, to: 4).map(&:to_a).should == [[2, 3]]
    Brute::Compaction::Transcript.turns(messages, from: 2, to: 8).map(&:to_a).should == [[2, 3], [4, 5, 6, 7]]

    Brute::Compaction::Transcript.at(messages, [0, 4]).map(&:content).should == ["instructions", "second question"]

    # Rendered for a summariser to read, a call is still tied to its result.
    Brute::Compaction::Transcript.render(messages[5..7]).should == [
      %(assistant: shell({"command":"ls"}) -> tc1),
      "tool: the result (answering tc1)",
      "assistant: done",
    ].join("\n")

    # Four characters to the token, plus a little per message for the envelope.
    Brute::Compaction::Transcript.tokens([message(:user, "a" * 40)]).should == 15

    # A strategy's own work is recognisable, so a later pass can leave it alone.
    note = message(:user, Brute::Compaction::Transcript.mark("sliding_window", "3 messages dropped"))
    Brute::Compaction::Transcript.marked?(note).should.be.true
    Brute::Compaction::Transcript.marked?(note, "sliding_window").should.be.true
    Brute::Compaction::Transcript.marked?(note, "summary").should.be.false
    Brute::Compaction::Transcript.marked?(message(:user, "second question")).should.be.false

    # ...and a note never anchors a task, however recent it is.
    Brute::Compaction::Transcript.task_index(messages + [note]).should == 4
  end
end
