# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Compaction
    module Middleware
      # When rewriting the tool output was not enough, whole stretches of the
      # conversation go.
      #
      # The instructions and the message the current task hangs off are never
      # given up. Past that, the oldest complete turns go first; only once every
      # turn is gone does the current task start losing its own oldest steps, and
      # never the newest.
      #
      # A note stands where the removed messages were, so the model can see that
      # something was there rather than quietly reasoning from a gap.
      class SlidingWindow < Strategy
        NOTE = "%d earlier messages were dropped to free context. They cannot be recovered."

        def initialize(app = nil, keep_steps: 1)
          @app = app
          @keep_steps = keep_steps
        end

        def strategy = "sliding_window"

        def rewrite(messages, target:)
          kept, note_index, dropped = split(messages, target)

          # Swapping one note for another frees nothing. The base would refuse
          # it anyway; declining here says why.
          if dropped.any? && !dropped.all? { |index| Brute::Compaction::Transcript.marked?(messages[index], strategy) }
            note = Brute::Message.new(
              role:    :user,
              content: Brute::Compaction::Transcript.mark(strategy, format(NOTE, dropped.length)),
            )
            [*kept[...note_index], note, *kept[note_index..]]
          end
        end

        private

          def split(messages, target)
            system_end = Brute::Compaction::Transcript.system_end(messages)
            anchor     = Array(Brute::Compaction::Transcript.task_index(messages))
            history    = Brute::Compaction::Transcript.turns(messages, from: system_end, to: anchor.first || system_end).map(&:to_a)
            steps      = Brute::Compaction::Transcript.steps(messages, from: Brute::Compaction::Transcript.step_start(messages)).map(&:to_a)

            budget = target - tokens(Brute::Compaction::Transcript.at(messages, [*0...system_end, *anchor]))
            first_turn, first_step = frontier(
              messages,
              history,
              steps,
              budget,
            )

            turn_indices = history[first_turn..].flatten
            step_indices = steps[first_step..].flatten
            kept = [*0...system_end, *turn_indices, *anchor, *step_indices]

            # The note goes where the messages it stands for used to sit: after
            # the instructions when only history went, after the anchor when the
            # task's own steps did.
            note_index = system_end
            if first_step.positive?
              note_index = system_end + turn_indices.length + anchor.length
            end

            [Brute::Compaction::Transcript.at(messages, kept), note_index, (0...messages.length).to_a - kept]
          end

          # How far into the history, and into the task's own steps, keeping has
          # to start for what remains to fit.
          def frontier(messages, history, steps, budget)
            spent = tokens(Brute::Compaction::Transcript.at(messages, steps.flatten))

            if spent > budget
              # The task alone overruns, so all history goes and its oldest steps
              # follow -- down to the newest, which stay regardless.
              floor = [steps.length - @keep_steps, 0].max
              [history.length, [first_kept(messages, steps, budget), floor].min]
            else
              [first_kept(messages, history, budget - spent), 0]
            end
          end

          # Newest group backwards, stopping at the first that does not fit.
          def first_kept(messages, groups, budget)
            position = groups.length
            remaining = budget

            while position.positive?
              cost = tokens(Brute::Compaction::Transcript.at(messages, groups[position - 1]))

              if cost > remaining
                break
              end

              remaining -= cost
              position -= 1
            end

            position
          end
      end
    end
  end
end

__END__

describe "brute/compaction/middleware/sliding_window" do
  def said(role, content) = Brute::Message.new(role: role, content: content)

  def compacted(conversation, target, **options)
    env = { conversation: conversation, target: target, applied: [], events: [] }
    Brute::Compaction::Middleware::SlidingWindow.new(->(e) { e }, **options).call(env)
    env
  end

  it "gives up the oldest turns first, then the task's oldest steps, and says what went" do
    conversation = [
      said(:system, "instructions"),
      said(:user, "first question"),
      said(:assistant, "a" * 4_000),
      said(:user, "second question"),
      said(:assistant, "b" * 4_000),
      said(:user, "third question"),
      said(:assistant, "c" * 400),
      said(:assistant, "d" * 400),
    ]

    # Room for the task and one historical turn, so the oldest turn goes and
    # the note takes its place, directly after the instructions.
    env = compacted(conversation, 1_400, keep_steps: 1)
    env[:conversation].map { |m| m.content[0, 24] }.should == [
      "instructions",
      "[compacted:sliding_windo",
      "second question",
      "bbbbbbbbbbbbbbbbbbbbbbbb",
      "third question",
      "cccccccccccccccccccccccc",
      "dddddddddddddddddddddddd",
    ]
    env[:conversation][1].content.should ==
      "[compacted:sliding_window] 2 earlier messages were dropped to free context. They cannot be recovered."

    # The conversation it was handed is left as it was found.
    conversation.length.should == 8

    # A target the task cannot fit inside: every turn goes, and the task's own
    # oldest step goes with them -- the note now sits after the anchor.
    tight = compacted(conversation, 150, keep_steps: 1)[:conversation]
    tight.map { |m| m.content[0, 24] }.should == [
      "instructions",
      "third question",
      "[compacted:sliding_windo",
      "dddddddddddddddddddddddd",
    ]

    # keep_steps holds the floor: the newest step survives any target at all.
    compacted(conversation, 0, keep_steps: 1)[:conversation].length.should == 4

    # Already inside the target, and a conversation that is nothing but a note.
    compacted(conversation, 100_000, keep_steps: 1)[:applied].should == []
    compacted(tight, 0, keep_steps: 1)[:applied].should == []
  end
end
