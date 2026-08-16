# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module PrimeAgent
  # The in-kernel runtime — loaded INTO the IRuby kernel by the bootstrap
  # cell (see KernelProvisioner / .bootstrap_code). Defines the model-facing
  # namespace as top-level methods available in every cell:
  #
  #   harness            — the continual harness proxy (harness_store.rb)
  #   get_harness_state  — the local store (`global_: true` for the global one)
  #   refine.run(...)    — schedule a /refine pass; runs when the turn ends
  #   refine.status      — pending request info
  #   compact.run(...)   — schedule compaction; runs when the turn ends
  #   compact.status     — context usage {tokens, context_window, percent, scheduled}
  #   rlm_heartbeat.*    — agent-owned recurring instructions (cron_store.rb)
  #   goal.get/create/complete — the persistent thread goal (goal.rb)
  #
  # prime-agent's kernel talks to its host over a comm bridge on the Jupyter
  # control channel; iruby's dispatch loop is single-threaded and has no
  # control channel, so the bridge here is a FILE pair per service:
  # `refine.run` atomically writes `<local harness dir>/refine_request.json`
  # (drained by AutoRefine at the next turn boundary) and `compact.run`
  # writes compact_request.json (drained by the Compaction middleware, which
  # publishes compact_status.json back). Harness CRUD needs no bridge at all
  # — both sides read/write harness_state.json directly with mtime re-sync
  # (exactly like prime-agent's Python store).
  #
  # Pure stdlib — this file and harness_store.rb must stay loadable without
  # brute or any gem.
  module KernelRuntime
    # `refine` in the kernel namespace.
    class RefineProxy
      def initialize(request_path:)
        @request_path = request_path
      end

      def run(instructions = nil, global_: false, rollback_id: nil)
        request = {
          "instructions" => instructions,
          "global" => global_ ? true : false,
          "rollback_id" => rollback_id,
          "requested_at" => Time.now.utc.iso8601,
        }
        FileUtils.mkdir_p(File.dirname(@request_path))
        tmp = "#{@request_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(request)}\n")
        File.rename(tmp, @request_path)
        "Refinement scheduled — it runs when the current turn ends; " \
          "harness changes appear in the system prompt on the next turn."
      end

      def status
        { "pending" => File.exist?(@request_path), "request_path" => @request_path }
      end
    end

    # `compact` in the kernel namespace — the port of prime-agent's bundled
    # `compact` skill (packages/coding-agent/skills/compact): context
    # compaction control from the kernel. Upstream calls the host over a comm
    # bridge (compact.run / compact.status); here the bridge is a FILE pair
    # in the local harness dir: `compact.run` atomically writes
    # compact_request.json, which the host's Compaction middleware drains at
    # the next turn boundary (never mid-cell), and `compact.status` reads
    # compact_status.json, which the middleware publishes every iteration.
    class CompactProxy
      def initialize(request_path:, status_path:)
        @request_path = request_path
        @status_path = status_path
      end

      # Schedule compaction. Returns {"scheduled" => true}; upstream can
      # answer {"scheduled": false, "reason": ...} synchronously from its
      # host bridge — the file bridge can't, so a nothing-to-compact drain
      # no-ops and is observable via #status instead.
      def run(instructions = nil)
        unless instructions.nil? || instructions.is_a?(String)
          raise TypeError, "instructions must be a String or nil, got #{instructions.class}"
        end

        request = {
          "instructions" => instructions,
          "requested_at" => Time.now.utc.iso8601,
        }
        FileUtils.mkdir_p(File.dirname(@request_path))
        tmp = "#{@request_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(request)}\n")
        File.rename(tmp, @request_path)
        { "scheduled" => true }
      end

      # Current context usage: {"tokens", "context_window", "percent",
      # "scheduled"}. percent is nil right after a compaction until the next
      # model response (published that way by the middleware).
      def status
        base =
          if File.exist?(@status_path)
            begin
              JSON.parse(File.read(@status_path))
            rescue JSON::ParserError
              {}
            end
          else
            {}
          end
        {
          "tokens" => base["tokens"],
          "context_window" => base["context_window"],
          "percent" => base["percent"],
          "scheduled" => File.exist?(@request_path) || base["scheduled"] == true,
        }
      end
    end

    # `rlm_heartbeat` in the kernel namespace — the port of prime-agent's
    # bundled `rlm-heartbeat` skill: agent-owned recurring instructions.
    # Upstream routes these through the host bridge; here the job store is
    # just a JSON file with atomic writes + flock (cron_store.rb), so the
    # proxy writes it DIRECTLY — the dual-writer pattern harness_state.json
    # already uses. The ScheduleDriver claims due jobs between runs.
    class RlmHeartbeatProxy
      def initialize(store_path:)
        @store_path = store_path
      end

      def list(include_inactive: false)
        unless include_inactive == true || include_inactive == false
          raise TypeError, "include_inactive must be true or false"
        end

        store.list_rlm_heartbeats(include_inactive: include_inactive).map { |job| serialize(job) }
      end

      def create(instruction, interval: nil, label: nil, delivery_mode: nil)
        raise TypeError, "instruction must be a String, got #{instruction.class}" unless instruction.is_a?(String)
        validate_optional_string("interval", interval)
        validate_optional_string("label", label)
        validate_optional_string("delivery_mode", delivery_mode)

        serialize(store.create_rlm_heartbeat(
          instruction: instruction, interval: interval, label: label, delivery_mode: delivery_mode,
        ))
      end

      def update(id, instruction: nil, interval: nil, label: nil, status: nil, delivery_mode: nil)
        raise TypeError, "id must be a String, got #{id.class}" unless id.is_a?(String)
        validate_optional_string("instruction", instruction)
        validate_optional_string("interval", interval)
        validate_optional_string("label", label)
        validate_optional_string("status", status)
        validate_optional_string("delivery_mode", delivery_mode)

        serialize(store.update_rlm_heartbeat(
          id, instruction: instruction, interval: interval, label: label,
          status: status, delivery_mode: delivery_mode,
        ))
      end

      def delete(id)
        raise TypeError, "id must be a String, got #{id.class}" unless id.is_a?(String)

        { "deleted" => true, "heartbeat" => serialize(store.delete_rlm_heartbeat(id)) }
      end

      private

      def store
        @store ||= PrimeAgent::CronStore.new(@store_path)
      end

      def validate_optional_string(name, value)
        return if value.nil? || value.is_a?(String)

        raise TypeError, "#{name} must be a String or nil, got #{value.class}"
      end

      # The kernel-facing shape (upstream's rlmHeartbeatHostResponse,
      # agent-session.ts): snake_case, instruction/schedule text.
      def serialize(job)
        {
          "id" => job.id,
          "status" => job.status,
          "label" => job.label,
          "delivery_mode" => job.delivery_mode,
          "instruction" => job.prompt,
          "schedule" => job.schedule["expression"],
          "created_at" => job.created_at,
          "updated_at" => job.updated_at,
          "next_run_at" => job.next_run_at,
          "last_run_at" => job.last_run_at,
          "last_error" => job.last_error,
          "run_count" => job.run_count,
        }
      end
    end

    # `goal` in the kernel namespace — the port of prime-agent's bundled
    # `goal` skill: manage the persistent thread goal from the kernel. All
    # goal state lives in goal.json in the local harness dir; `get` reads it
    # directly (dual-reader, like harness CRUD) and mutations write
    # goal_request.json, which the host's Goal middleware drains at the next
    # turn boundary (never mid-cell).
    class GoalProxy
      def initialize(store_path:, request_path:)
        @store_path = store_path
        @request_path = request_path
      end

      # Current goal: {"goal", "remaining_tokens", "completion_budget_report"}.
      def get
        PrimeAgent::Goal.host_response(PrimeAgent::Goal.load_state(@store_path))
      end

      # Start a new active thread goal. Only when the user or system
      # instructions explicitly ask for a persistent long-running goal — and
      # only when no goal is pending (a completed or errored goal is
      # replaced). Validated here; the middleware applies it at the boundary.
      def create(objective, token_budget: nil)
        raise TypeError, "objective must be a String, got #{objective.class}" unless objective.is_a?(String)
        unless token_budget.nil? || token_budget.is_a?(Integer)
          raise TypeError, "token_budget must be an Integer or nil, got #{token_budget.class}"
        end

        objective = PrimeAgent::Goal.validate_objective(objective)
        token_budget = PrimeAgent::Goal.validate_budget(token_budget)
        state = PrimeAgent::Goal.load_state(@store_path)
        if state.objective && %w[active paused budget_limited].include?(state.status)
          raise "a thread goal is still pending (status: #{state.status}); " \
                "a completed or errored goal can be replaced, a pending one cannot"
        end

        write_request("action" => "create", "objective" => objective, "token_budget" => token_budget)
        { "scheduled" => true }
      end

      # Mark the existing thread goal achieved — only when it actually is.
      def complete
        state = PrimeAgent::Goal.load_state(@store_path)
        if state.objective.nil? || state.status == "idle"
          raise "no thread goal to complete"
        end

        write_request("action" => "complete")
        { "scheduled" => true }
      end

      private

      def write_request(request)
        FileUtils.mkdir_p(File.dirname(@request_path))
        tmp = "#{@request_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{JSON.pretty_generate(request.merge("requested_at" => Time.now.utc.iso8601))}\n")
        File.rename(tmp, @request_path)
      end
    end

    # The bootstrap cell executed right after the kernel boots. Paths are
    # interpolated as Ruby literals via #inspect.
    def self.bootstrap_code(harness_store_path:, local_dir:, global_dir:, request_path:, skill_lib_glob: nil,
                            kernel_agents_path: File.expand_path("kernel_agents.rb", __dir__),
                            cron_store_path: File.expand_path("cron_store.rb", __dir__),
                            goal_path: File.expand_path("goal.rb", __dir__),
                            bundle_gemfile: File.expand_path("../../Gemfile", __dir__))
      <<~RUBY
        load #{File.expand_path(harness_store_path).inspect}
        load #{File.expand_path(__FILE__).inspect}
        load #{File.expand_path(kernel_agents_path).inspect}
        load #{File.expand_path(cron_store_path).inspect}
        load #{File.expand_path(goal_path).inspect}
        PrimeAgent::KernelRuntime.install!(
          harness_store_path: #{File.expand_path(harness_store_path).inspect},
          local_dir: #{local_dir.inspect},
          global_dir: #{global_dir.inspect},
          request_path: #{request_path.inspect},
          skill_lib_glob: #{skill_lib_glob.inspect},
          kernel_agents_path: #{File.expand_path(kernel_agents_path).inspect},
          cron_store_path: #{File.expand_path(cron_store_path).inspect},
          goal_path: #{File.expand_path(goal_path).inspect},
          bundle_gemfile: #{bundle_gemfile.inspect}
        )
        "prime-agent kernel runtime ready"
      RUBY
    end

    def self.install!(local_dir:, global_dir:, request_path:, harness_store_path:, skill_lib_glob: nil,
                      kernel_agents_path: nil, cron_store_path: nil, goal_path: nil, bundle_gemfile: nil)
      load harness_store_path unless defined?(PrimeAgent::HarnessStore)
      load cron_store_path if cron_store_path && !defined?(PrimeAgent::CronStore)
      load goal_path if goal_path && !defined?(PrimeAgent::Goal)

      harness = PrimeAgent::Harness.new(
        local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
        global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
      )
      refine = RefineProxy.new(request_path: request_path)
      compact = CompactProxy.new(
        request_path: File.join(local_dir, "compact_request.json"),
        status_path: File.join(local_dir, "compact_status.json"),
      )
      rlm_heartbeat = RlmHeartbeatProxy.new(store_path: File.join(local_dir, "scheduled-jobs.json"))
      goal = GoalProxy.new(
        store_path: File.join(local_dir, "goal.json"),
        request_path: File.join(local_dir, "goal_request.json"),
      )

      Array(skill_lib_glob).compact.each do |glob|
        Dir.glob(glob).each { |dir| $LOAD_PATH.unshift(dir) unless $LOAD_PATH.include?(dir) }
      end

      if kernel_agents_path
        load kernel_agents_path unless defined?(PrimeAgent::KernelAgents)
        PrimeAgent::KernelAgents.bundle_gemfile = bundle_gemfile
        Object.const_set(:KernelAgent, PrimeAgent::KernelAgents) unless defined?(::KernelAgent)
      end

      runtime = Module.new do
        define_method(:harness) { harness }
        define_method(:refine) { refine }
        define_method(:compact) { compact }
        define_method(:rlm_heartbeat) { rlm_heartbeat }
        define_method(:goal) { goal }
        define_method(:get_harness_state) { |global_: false| harness.get_harness_state(global_: global_) }
      end
      Object.include(runtime)
      harness
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/kernel_runtime" do
  it "RefineProxy#run writes the request file atomically; #status reports it" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "refine_request.json")
      proxy = PrimeAgent::KernelRuntime::RefineProxy.new(request_path: path)

      proxy.status["pending"].should.be.false
      message = proxy.run("save the rg lesson", global_: false)
      message.should.include "Refinement scheduled"
      proxy.status["pending"].should.be.true

      request = JSON.parse(File.read(path))
      request["instructions"].should == "save the rg lesson"
      request["global"].should == false
      request["rollback_id"].should.be.nil
      request["requested_at"].should.not.be.nil
    end
  end

  it "CompactProxy#run writes the request file; #status reads the published status" do
    Dir.mktmpdir do |dir|
      request_path = File.join(dir, "compact_request.json")
      status_path = File.join(dir, "compact_status.json")
      proxy = PrimeAgent::KernelRuntime::CompactProxy.new(request_path: request_path, status_path: status_path)

      proxy.status.should == { "tokens" => nil, "context_window" => nil, "percent" => nil, "scheduled" => false }
      proxy.run("keep the failing tests").should == { "scheduled" => true }
      proxy.status["scheduled"].should.be.true
      JSON.parse(File.read(request_path))["instructions"].should == "keep the failing tests"

      File.write(status_path, JSON.generate("tokens" => 100, "context_window" => 1000,
                                            "percent" => 10.0, "scheduled" => false))
      proxy.status["percent"].should == 10.0
      proxy.status["scheduled"].should.be.true # the pending request wins

      lambda { proxy.run(123) }.should.raise(TypeError)
    end
  end

  it "RlmHeartbeatProxy does CRUD against the store file in the kernel-facing shape" do
    Dir.mktmpdir do |dir|
      proxy = PrimeAgent::KernelRuntime::RlmHeartbeatProxy.new(
        store_path: File.join(dir, "scheduled-jobs.json"),
      )
      created = proxy.create("check the test run", interval: "5m", label: "tests")
      created["status"].should == "active"
      created["instruction"].should == "check the test run"
      created["schedule"].should == "5m" # expressions are stored verbatim
      created["delivery_mode"].should == "steer"
      created["run_count"].should == 0

      proxy.list.map { |h| h["label"] }.should == ["tests"]
      proxy.update(created["id"], status: "pause")["status"].should == "paused"
      proxy.list.should == []
      proxy.list(include_inactive: true).length.should == 1
      proxy.delete(created["id"])["deleted"].should.be.true
      proxy.list(include_inactive: true).should == []

      lambda { proxy.create(42) }.should.raise(TypeError)
      lambda { proxy.update(created["id"], status: "explode") }.should.raise(ArgumentError)
    end
  end

  it "GoalProxy validates, schedules create/complete, and reads state back" do
    require_relative "goal"
    Dir.mktmpdir do |dir|
      store_path = File.join(dir, "goal.json")
      proxy = PrimeAgent::KernelRuntime::GoalProxy.new(
        store_path: store_path, request_path: File.join(dir, "goal_request.json"),
      )

      proxy.get.should == { "goal" => nil, "remaining_tokens" => nil, "completion_budget_report" => nil }
      lambda { proxy.complete }.should.raise(RuntimeError) # no goal to complete

      proxy.create("ship the release", token_budget: 5000).should == { "scheduled" => true }
      request = JSON.parse(File.read(File.join(dir, "goal_request.json")))
      request["action"].should == "create"
      request["objective"].should == "ship the release"

      # The store itself is untouched until the middleware drains the request;
      # a completed/errored goal is replaceable, a pending one is not.
      PrimeAgent::Goal.save_state(store_path, PrimeAgent::Goal.load_state(store_path))
      lambda { proxy.create(42) }.should.raise(TypeError)
      lambda { proxy.create("x" * 4001) }.should.raise(ArgumentError)
      lambda { proxy.create("ok", token_budget: 0) }.should.raise(ArgumentError)

      PrimeAgent::Goal.create_in_store(store_path, objective: "active goal")
      lambda { proxy.create("another") }.should.raise(RuntimeError) # pending
      proxy.complete.should == { "scheduled" => true }
      JSON.parse(File.read(File.join(dir, "goal_request.json")))["action"].should == "complete"
    end
  end

  it "bootstrap_code embeds the runtime paths as Ruby literals" do
    code = PrimeAgent::KernelRuntime.bootstrap_code(
      harness_store_path: "lib/prime_agent/harness_store.rb",
      local_dir: "/tmp/local",
      global_dir: "/tmp/global",
      request_path: "/tmp/local/refine_request.json",
      skill_lib_glob: "/work/.brute/skills/*/lib",
    )
    code.should.include 'load "'
    code.should.include "harness_store.rb"
    code.should.include "kernel_runtime.rb"
    code.should.include 'local_dir: "/tmp/local"'
    code.should.include 'global_dir: "/tmp/global"'
    code.should.include 'request_path: "/tmp/local/refine_request.json"'
    code.should.include 'skill_lib_glob: "/work/.brute/skills/*/lib"'
  end
end
