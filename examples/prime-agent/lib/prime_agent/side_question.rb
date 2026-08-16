# frozen_string_literal: true

require "brute"

module PrimeAgent
  # SideQuestion — the port of prime-agent's `/btw` (core/side-question.ts):
  # a one-off question against the current conversation WITHOUT touching the
  # main session. The conversation is deep-cloned, the question is wrapped
  # <side_question>…</side_question> (the first turn prepends the
  # instruction), and exactly one turn runs with no tools. Follow-ups replay
  # prior Q&A as synthetic pairs against a fresh clone of the live
  # conversation (upstream re-clones per follow-up).
  module SideQuestion
    INSTRUCTION =
      "Answer this side question using only the conversation context above. " \
      "Do not use tools. The user may send follow-up side questions; none of " \
      "this side conversation is added to the main session."

    module_function

    # Returns [answer_text, turns] — turns accumulates {question, answer}
    # pairs for follow-up calls.
    def ask(messages:, question:, terminal:, turns: [])
      conversation = messages.map { |message| Brute::Message.new(**message.to_h) }
      turns.each do |turn|
        conversation << Brute::Message.new(role: :user, content: wrap(turn.fetch(:question), first: false))
        conversation << Brute::Message.new(role: :assistant, content: turn.fetch(:answer))
      end
      conversation << Brute::Message.new(role: :user, content: wrap(question, first: turns.empty?))

      env = Brute.agent.run(terminal).start(conversation)
      answer = env[:messages].reverse.find { |message| message.role == :assistant }&.content.to_s
      [answer, turns + [{ question: question, answer: answer }]]
    end

    def wrap(question, first:)
      body = first ? "#{INSTRUCTION}\n\n#{question}" : question
      "<side_question>\n#{body}\n</side_question>"
    end
  end
end

__END__

describe "prime_agent/side_question" do
  require "brute/messages"

  def terminal_recording(calls)
    lambda do |env|
      calls << env[:messages].map { |m| [m.role, m.content] }
      env[:messages] << Brute::Message.new(role: :assistant, content: "side answer")
      env
    end
  end

  it "clones the conversation, wraps the question with the first-turn instruction, and never touches the source" do
    calls = []
    source = Brute.log
    source.system("sys")
    source.user("main question")
    source.assistant("main answer")
    size = source.size

    answer, = PrimeAgent::SideQuestion.ask(
      messages: source, question: "what did we decide?", terminal: terminal_recording(calls),
    )

    answer.should == "side answer"
    source.size.should == size # the main conversation is untouched
    sent = calls.first
    sent.last.first.should == :user
    sent.last.last.should.include "<side_question>"
    sent.last.last.should.include PrimeAgent::SideQuestion::INSTRUCTION
    sent.last.last.should.include "what did we decide?"
    sent.map(&:first).should == %i[system user assistant user] # full clone + the question
  end

  it "replays follow-ups without the instruction" do
    calls = []
    turns = [{ question: "first", answer: "a1" }]
    PrimeAgent::SideQuestion.ask(
      messages: Brute.log, question: "second", terminal: terminal_recording(calls), turns: turns,
    )
    sent = calls.first
    sent[0].last.should.include "<side_question>\nfirst\n</side_question>"
    sent[0].last.should.not.include PrimeAgent::SideQuestion::INSTRUCTION
    sent[1].should == [:assistant, "a1"]
    sent[2].last.should.include "second"
  end
end
