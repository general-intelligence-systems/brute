# frozen_string_literal: true

require "securerandom"

# Subturns — picoclaw's child-turn machinery (pkg/agent/subturn.go,
# turn_state.go), adapted to a one-shot process.
#
# Backs the spawn/subagent tools. Children run the same agent stack with an
# ephemeral in-memory session, a fixed subagent system prompt, and the
# parent's tool registry MINUS spawn/subagent/spawn_status (no recursive
# spawning). Guards: depth <= 3, concurrency <= 5 (30s acquire timeout),
# 5-min default child timeout.
#
# Sync (subagent tool) blocks and returns the child's final text. Async
# (spawn tool) returns an ack immediately and runs the child on a thread;
# finished child results are drained into the parent as "[SubTurn Result]"
# user messages at iteration boundaries. Before the turn ends, critical
# children still running are joined (bounded by their remaining timeout) and
# their results injected — a one-shot process must not orphan them.
#
# env reads: :messages. env writes: :messages (result injection),
# env[:metadata][:subturns]. Side effects: child agent runs (threads).
class Subturns
  SYSTEM_PROMPT = "You are a subagent. Complete the given task independently and report the result.\n" \
                  "You have access to tools - use them as needed to complete your task.\n" \
                  "After completing the task, provide a clear summary of what was done."

  # Shared between the middleware and the spawn/subagent/spawn_status tools.
  class Registry
    Task = Struct.new(:id, :label, :task, :status, :result, :thread, :started_at, :critical)

    attr_reader :build_child

    def initialize(max_depth: 3, max_concurrent: 5, concurrency_timeout: 30,
                   default_timeout_minutes: 5, &build_child)
      @max_depth = max_depth
      @semaphore = SizedQueue.new(max_concurrent)
      max_concurrent.times { @semaphore << true }
      @concurrency_timeout = concurrency_timeout
      @timeout_seconds = default_timeout_minutes.to_i * 60
      @build_child = build_child
      @tasks = []
      @counter = 0
      @mutex = Mutex.new
    end

    def next_id
      @mutex.synchronize { @counter += 1; "subagent-#{@counter}" }
    end

    def tasks = @mutex.synchronize { @tasks.dup }

    def find(id) = tasks.find { |t| t.id == id }

    def acquire
      Timeout.timeout(@concurrency_timeout) { @semaphore.pop }
      true
    rescue Timeout::Error
      false
    end

    def release = (@semaphore << true)

    # depth guard happens in the tools (via env metadata).
    def register(task)
      @mutex.synchronize { @tasks << task }
      task
    end

    def timeout_seconds = @timeout_seconds
  end

  def initialize(app, registry:)
    @app = app
    @registry = registry
  end

  def call(env)
    env[:metadata][:subturns] = @registry
    env[:metadata][:subturn_depth] = env[:metadata][:subturn_depth].to_i

    result = @app.call(env)

    join_critical_children(env)
    result
  end

  private

  # A one-shot process cannot orphan critical children: join the survivors
  # (bounded by their timeouts) and inject their results before unwinding.
  def join_critical_children(env)
    @registry.tasks.each do |task|
      next unless task.thread&.alive?

      remaining = task.started_at + @registry.timeout_seconds - Time.now
      task.thread.join([remaining, 1].max)
      next unless task.status == "completed"

      env[:messages] << Brute::Message.new(role: :user, content: result_message(task))
    end
  end

  def result_message(task)
    label = task.label.to_s.empty? ? task.id : task.label
    "[SubTurn Result] #{label}\n#{task.result}"
  end
end
