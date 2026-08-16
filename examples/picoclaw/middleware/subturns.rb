# frozen_string_literal: true

require "securerandom"
require "timeout"

# Subturns — picoclaw's child-turn machinery (pkg/agent/subturn.go,
# turn_state.go), adapted to a one-shot process.
#
# Backs the spawn/subagent/spawn_status tools. Children run the same agent
# stack with an ephemeral session, a fixed subagent system prompt, and the
# parent's tools MINUS spawn/subagent/spawn_status (no recursive spawning).
# Guards: depth <= 3, concurrency <= 5 (30s acquire timeout), 5-min default
# child timeout.
#
# Sync (subagent) blocks and returns the child's final text. Async (spawn)
# returns an ack immediately and runs the child on a thread; Subturns::Drain
# (per-iteration, inside the loop) injects finished results into the parent
# as "[SubTurn Result]" user messages. Before the turn ends, critical
# children still running are joined (bounded by their timeouts) — a one-shot
# process must not orphan them.
class Subturns
  SYSTEM_PROMPT = "You are a subagent. Complete the given task independently and report the result.\n" \
                  "You have access to tools - use them as needed to complete your task.\n" \
                  "After completing the task, provide a clear summary of what was done."

  # Shared between the middleware and the spawn/subagent/spawn_status tools.
  class Registry
    Task = Struct.new(:id, :label, :task, :status, :result, :thread, :started_at, :reported, :target)

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

    def next_id = @mutex.synchronize { @counter += 1; "subagent-#{@counter}" }
    def tasks = @mutex.synchronize { @tasks.dup }
    def find(id) = tasks.find { |t| t.id == id }
    def timeout_seconds = @timeout_seconds

    def register(task) = @mutex.synchronize { @tasks << task; task }

    def acquire
      Timeout.timeout(@concurrency_timeout) { @semaphore.pop }
      true
    rescue Timeout::Error
      false
    end

    def release
      @semaphore << true
      nil
    end
  end

  def initialize(app, registry:)
    @app = app
    @registry = registry
  end

  def call(env)
    env[:metadata][:subturns] = @registry
    @app.call(env)
    join_critical_children(env)
    env
  end

  # A one-shot process cannot orphan children: join the survivors (bounded by
  # their remaining timeouts) and inject any unreported results.
  def join_critical_children(env)
    @registry.tasks.each do |task|
      next unless task.thread&.alive?

      remaining = task.started_at + @registry.timeout_seconds - Time.now
      task.thread.join([remaining, 1].max)
      Drain.inject(env, @registry)
    end
  end

  # Runs one child turn (ephemeral session, fixed subagent prompt, no spawn
  # tools — the child stack is built by the registry's build_child proc) with
  # the default timeout; records status/result and releases the slot.
  # record.target (an agent config hash) delegates into that agent's
  # workspace/model.
  def self.run_child(registry, record)
    Timeout.timeout(registry.timeout_seconds) do
      env = registry.build_child.call(record.task, record.target)
      final = env[:messages].reverse.find { |m| m.role.to_sym == :assistant && !m.content.to_s.strip.empty? }
      record.result = final&.content.to_s
      record.status = "completed"
    end
  rescue Timeout::Error
    record.status = "failed"
    record.result = "subagent timed out after #{registry.timeout_seconds}s"
  rescue StandardError => e
    record.status = "failed"
    record.result = e.message
  ensure
    registry.release
  end

  # Per-iteration result drain (upstream's pendingResults poll).
  class Drain
    def initialize(app, registry:)
      @app = app
      @registry = registry
    end

    def call(env)
      self.class.inject(env, @registry)
      @app.call(env)
    end

    def self.inject(env, registry)
      registry.tasks.each do |task|
        next unless task.status == "completed" && !task.reported

        task.reported = true
        label = task.label.to_s.empty? ? task.id : task.label
        env[:messages] << Brute::Message.new(role: :user, content: "[SubTurn Result] #{label}\n#{task.result}")
      end
    end
  end
end
