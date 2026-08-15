# frozen_string_literal: true

require_relative "session_store"

# SteeringLoop — picoclaw's steering (pkg/agent/steering.go), adapted to
# brute's middleware pipeline with the filesystem as the input channel.
#
#   steer.jsonl     one user message per line, appended by any external
#                   process; drained at the loop-condition boundary (after
#                   each full LLM+tools pass). Queue cap 10 like picoclaw's
#                   MaxQueueSize; overflow stays in the file for the next poll.
#   interrupt       graceful interrupt: its content is appended as a hint and
#                   the loop takes exactly one more pass. (Upstream strips the
#                   tool defs for that pass; brute's pipeline can't, so tools
#                   remain available on the final pass — noted delta.)
#   abort           hard abort: env is rolled back to the pre-turn session
#                   restore point (SessionStore) and the loop exits.
#
# steering_mode "one-at-a-time" (default) drains one message per poll; "all"
# drains the queue (up to the cap). A final text answer never ends the turn
# while the queue has messages (picoclaw's "stale answer" case).
class SteeringLoop < Brute::Middleware::Loop
  MAX_QUEUE_SIZE = 10

  def initialize(app, queue: File.join(Dir.pwd, "steer.jsonl"),
                 interrupt_file: File.join(Dir.pwd, "interrupt"),
                 abort_file: File.join(Dir.pwd, "abort"),
                 mode: "one-at-a-time")
    @mode = mode.to_s
    @graceful = false
    super(app, condition(queue, interrupt_file, abort_file))
  end

  private

  def condition(queue, interrupt_file, abort_file)
    lambda do |env|
      if File.exist?(abort_file)
        File.delete(abort_file)
        SessionStore.rollback!(env)
        env[:should_exit] = true
        next false
      end

      if @graceful
        @graceful = false
        next false # the hinted pass already ran; stop
      end

      if File.exist?(interrupt_file)
        hint = File.read(interrupt_file).strip
        File.delete(interrupt_file)
        hint = "The user interrupted: wrap up now with a final answer." if hint.empty?
        env[:messages] << Brute::Message.new(role: :user, content: hint)
        @graceful = true
        env[:current_iteration] += 1
        next true
      end

      next false if env[:should_exit]

      if drain(queue, env)
        env[:current_iteration] += 1
        next true
      end

      next false unless env[:messages].last&.role.to_sym == :tool

      env[:current_iteration] += 1
      true
    end
  end

  def drain(queue, env)
    return false unless File.exist?(queue)

    lines = File.readlines(queue).map(&:strip).reject(&:empty?)
    return false if lines.empty?

    take = @mode == "all" ? MAX_QUEUE_SIZE : 1
    drained = lines.first(take)
    rest = lines.drop(take)
    File.write(queue, rest.empty? ? "" : "#{rest.join("\n")}\n")
    drained.each { |line| env[:messages] << Brute::Message.new(role: :user, content: line) }
    true
  end
end
