# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Compaction
    module Middleware
      # The cheapest thing to give up first: what the tools said.
      #
      # Tool output dominates a long run, and most of it stops being useful the
      # moment the model has acted on it. So the results are rewritten in place
      # rather than removed -- every call keeps the result that answers it, the
      # model can still see what it ran, and it can run it again if it turns out
      # it still needed the answer.
      #
      # Oldest first, and it stops the moment the transcript is under target, so
      # the most recent output survives the longest.
      class ToolResults < Strategy
        PLACEHOLDER = "Result dropped to free context. Call %s again if you still need it."

        def initialize(app = nil, keep_steps: 1, min_tokens: 200)
          if keep_steps < 1
            raise ArgumentError, "keep_steps must be at least 1: the model has not acted on the newest results yet"
          end

          @app = app
          @keep_steps = keep_steps
          @min_tokens = min_tokens
        end

        def strategy = "tool_results"

        def rewrite(messages, target:)
          guarded = guarded_indices(messages)
          names   = tool_names(messages)
          pruned  = messages.dup
          running = tokens(messages)
          changed = false

          messages.each_with_index do |message, index|
            if running <= target
              break
            end

            replacement = prune(message, names[message.tool_call_id])

            unless guarded.include?(index) || replacement.nil?
              running -= tokens([message]) - tokens([replacement])
              pruned[index] = replacement
              changed = true
            end
          end

          if changed
            pruned
          end
        end

        private

          # The newest tool-calling steps are never touched, however far over
          # target that leaves the transcript.
          def guarded_indices(messages)
            Brute::Compaction::Transcript.steps(messages, from: 0)
              .select { |span| span.count > 1 }
              .last(@keep_steps)
              .flat_map(&:to_a)
          end

          # A tool result carries an id, not a name -- the name is on the call it
          # answers, so the placeholder has to go and find it.
          def tool_names(messages)
            messages.each_with_object({}) do |message, names|
              message.tool_calls&.each { |call| names[call.id] = call.name }
            end
          end

          def prune(message, name)
            if message.role == :tool && !Brute::Compaction::Transcript.marked?(message) &&
               tokens([message]) > @min_tokens
              Brute::Message.new(
                role:         :tool,
                content:      Brute::Compaction::Transcript.mark(strategy, format(PLACEHOLDER, name || "the tool")),
                tool_call_id: message.tool_call_id,
              )
            end
          end
      end
    end
  end
end

__END__

describe "brute/compaction/middleware/tool_results" do
  def call(id) = { id: id, name: "shell", arguments: { "command" => "ls" } }
  def result(id, size) = Brute::Message.new(role: :tool, content: "x" * size, tool_call_id: id)
  def calling(id) = Brute::Message.new(role: :assistant, content: "", tool_calls: [call(id)])

  def compacted(conversation, target, **options)
    env = { conversation: conversation, target: target, applied: [], events: [] }
    Brute::Compaction::Middleware::ToolResults.new(->(e) { e }, **options).call(env)
    env
  end

  it "replaces the oldest fat tool results, guarding the newest step, and stops at the target" do
    conversation = [
      Brute::Message.new(role: :system, content: "instructions"),
      Brute::Message.new(role: :user, content: "go"),
      calling("tc1"), result("tc1", 8_000),
      calling("tc2"), result("tc2", 8_000),
      calling("tc3"), result("tc3", 8_000),
    ]

    env = compacted(conversation, 4_500, keep_steps: 1, min_tokens: 200)
    kept = env[:conversation]

    # The oldest result went. The placeholder names the tool that produced it,
    # and it keeps the id, so the call it answers is still answered.
    kept[3].content.should ==
      "[compacted:tool_results] Result dropped to free context. Call shell again if you still need it."
    kept[3].tool_call_id.should == "tc1"

    # One was enough to reach the target, so the next is untouched...
    kept[5].content.should == "x" * 8_000
    # ...and the newest step is guarded whatever the target says.
    kept[7].content.should == "x" * 8_000

    # The conversation it was handed is left as it was found.
    conversation[3].content.should == "x" * 8_000
    env[:applied].should == [{ strategy: "tool_results", before: 6_088, after: 4_111 }]

    # A harsher target reaches further back, but never past the guard.
    again = compacted(kept, 1, keep_steps: 1, min_tokens: 200)[:conversation]
    Brute::Compaction::Transcript.marked?(again[5]).should.be.true
    again[7].content.should == "x" * 8_000

    # Nothing left to give up, already under target, or nothing fat enough.
    compacted(again, 1, keep_steps: 1, min_tokens: 200)[:applied].should == []
    compacted(conversation, 100_000, keep_steps: 1)[:applied].should == []
    compacted(conversation, 1, keep_steps: 1, min_tokens: 100_000)[:applied].should == []

    should.raise(ArgumentError) { Brute::Compaction::Middleware::ToolResults.new(->(e) { e }, keep_steps: 0) }
  end
end
