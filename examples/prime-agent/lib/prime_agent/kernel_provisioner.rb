# frozen_string_literal: true

require_relative "kernel_manager"

module PrimeAgent
  # Lazy kernel provisioning — the port of prime-agent's
  # IpythonKernelProvisioner (packages/coding-agent/src/core/tools/
  # ipython.ts:463-525). The kernel is not spawned on agent startup but on
  # the model's first `iruby` tool call; the bootstrap cell then prepares
  # the runtime namespace (stage 3 loads the harness/`refine` runtime).
  class KernelProvisioner
    class Error < StandardError; end

    # snapshot_path (M17): when set, the kernel's namespace is restored from
    # it before the bootstrap cell (upstream: live handles shadow restored
    # names), snapshotted again 1.5s after the last ok execute (debounced,
    # upstream's DEFAULT_SNAPSHOT_DEBOUNCE_MS), and flushed once at shutdown.
    # Snapshots are Marshalled per-name; undumpable values drop + report.
    def initialize(cwd:, bootstrap: nil, kernel_class: KernelManager,
                   snapshot_path: nil, snapshot_debounce: 1.5, snapshot_max_bytes: 256 * 1024 * 1024)
      @cwd = cwd
      @bootstrap = bootstrap # String, or a callable returning a String
      @kernel_class = kernel_class
      @snapshot_path = snapshot_path
      @snapshot_debounce = snapshot_debounce
      @snapshot_max_bytes = snapshot_max_bytes
      @manager = nil
      @mutex = Mutex.new
      @snapshot_dirty = false
      @snapshot_generation = 0
      @snapshot_thread = nil
      @shutdown = false
    end

    # The running kernel manager, booting + bootstrapping on first use.
    def kernel
      @mutex.synchronize { @manager ||= boot }
    end

    def execute(code, **options)
      result = kernel.execute(code, **options)
      mark_snapshot_dirty if @snapshot_path && result.status == "ok"
      unless result.attachments.empty?
        pending_attachments.concat(result.attachments)
      end
      result
    end

    # Attachment payloads (attach-image skill) collected since the last
    # drain — the AttachImages middleware turns them into model-visible
    # image messages.
    def drain_attachments
      pending_attachments.slice!(0, pending_attachments.length)
    end

    def pending_attachments
      @pending_attachments ||= []
    end

    # Whether the kernel has been provisioned (says nothing about liveness —
    # the manager itself tracks that).
    def provisioned?
      !@manager.nil?
    end

    def shutdown
      @mutex.synchronize do
        @shutdown = true
        flush_snapshot if @manager && @snapshot_path # the bounded final snapshot
        @manager&.shutdown
        @manager = nil
        @snapshot_thread&.join(1)
        @snapshot_thread = nil
      end
      nil
    end

    private

    # Boot on a plain thread. omq's Ruby backend pins each socket's IO engine
    # to Async::Task.current at connect time, falling back to omq's shared IO
    # thread when there is none (OMQ::Reactor / engine/socket_lifecycle.rb
    # capture_parent_task). The first tool call arrives inside brute's
    # per-batch Sync barrier, whose task tree dies when the batch completes —
    # taking the engines' recv pump with it and hanging every later execute.
    # Booting off the fiber machinery keeps the engines on the shared IO
    # thread, so cells execute from any fiber (per-batch Sync blocks included).
    def boot
      Thread.new { boot_manager }.value
    end

    def boot_manager
      manager = @kernel_class.new(cwd: @cwd)
      manager.start
      code = @bootstrap.respond_to?(:call) ? @bootstrap.call : @bootstrap
      if code
        result = manager.execute(code)
        unless result.status == "ok"
          details = [
            result.stderr,
            result.error && Array(result.error["traceback"]).join("\n"),
          ].compact.reject(&:empty?).join("\n")
          raise Error, "Failed to initialize prime-agent runtime in the IRuby kernel:\n#{details}"
        end
      end
      manager
    rescue StandardError
      manager&.shutdown
      raise
    end

    # Debounced auto-snapshot: every ok execute marks the state dirty and
    # bumps the generation; the timer thread flushes only when the log has
    # been quiet for the debounce window.
    def mark_snapshot_dirty
      @snapshot_dirty = true
      @snapshot_generation += 1
      @snapshot_thread ||= Thread.new { snapshot_loop }
    end

    def snapshot_loop
      loop do
        seen = @snapshot_generation
        sleep @snapshot_debounce
        break if @shutdown
        next if seen != @snapshot_generation
        next unless @snapshot_dirty

        flush_snapshot
      end
    end

    def flush_snapshot
      manifest = "#{@snapshot_path}.json"
      @manager.execute(
        "PrimeAgent::KernelRuntime.snapshot_state(binding, #{@snapshot_path.inspect}, " \
        "manifest_path: #{manifest.inspect}, max_bytes: #{@snapshot_max_bytes})",
      )
      @snapshot_dirty = false
    rescue StandardError
      nil # snapshots are best-effort; a failed flush never breaks a run
    end
  end
end

__END__

describe "prime_agent/kernel_provisioner" do
  require "tmpdir"

  FakeKernel = Class.new do
    Result = PrimeAgent::KernelManager::Result

    attr_reader :cwd, :executed, :shutdowns

    def initialize(cwd:, fail_bootstrap: false)
      @cwd = cwd
      @started = false
      @executed = []
      @shutdowns = 0
      @fail_bootstrap = fail_bootstrap
    end

    def start
      @started = true
      self
    end

    def execute(code, **)
      @executed << code
      if @fail_bootstrap
        Result.new(stdout: "", stderr: "LoadError: nope", result: nil,
                   status: "error", error: { "traceback" => ["tb"] }, duration_ms: 1, diffs: [], attachments: [])
      else
        Result.new(stdout: "ok", stderr: "", result: nil,
                   status: "ok", error: nil, duration_ms: 1, diffs: [], attachments: [])
      end
    end

    def shutdown
      @shutdowns += 1
    end
  end

  # Returns [provisioner, registry-of-created-fake-kernels]. Fresh registry
  # per call — scampi reuses the describe context across `it` blocks.
  def build_provisioner(bootstrap: "BOOTSTRAP", fail_bootstrap: false, snapshot_path: nil, snapshot_debounce: 1.5)
    registry = []
    factory = Class.new(FakeKernel) do
      define_method(:initialize) do |cwd:|
        super(cwd: cwd, fail_bootstrap: fail_bootstrap)
        registry << self
      end
    end
    [PrimeAgent::KernelProvisioner.new(cwd: "/tmp", bootstrap: bootstrap, kernel_class: factory,
                                       snapshot_path: snapshot_path, snapshot_debounce: snapshot_debounce),
     registry]
  end

  it "boots lazily — not until the first execute" do
    prov, registry = build_provisioner
    registry.should.be.empty
    prov.execute("1 + 1")
    registry.length.should == 1
  end

  it "runs the bootstrap cell once and memoizes the kernel" do
    prov, registry = build_provisioner(bootstrap: "BOOTSTRAP_CODE")
    prov.execute("a = 1")
    prov.execute("a + 1")
    registry.first.executed.should == ["BOOTSTRAP_CODE", "a = 1", "a + 1"]
    registry.length.should == 1
  end

  it "accepts a callable bootstrap" do
    prov, registry = build_provisioner(bootstrap: -> { "FROM_CALLABLE" })
    prov.execute("x")
    registry.first.executed.first.should == "FROM_CALLABLE"
  end

  it "raises and shuts the kernel down when the bootstrap cell fails" do
    prov, registry = build_provisioner(fail_bootstrap: true)
    lambda { prov.execute("x") }.should.raise(PrimeAgent::KernelProvisioner::Error)
    registry.first.shutdowns.should.be >= 1
    prov.provisioned?.should.be.false
  end

  it "shutdown is idempotent and clears the memoized kernel" do
    prov, registry = build_provisioner(bootstrap: nil)
    prov.execute("x")
    prov.provisioned?.should.be.true
    prov.shutdown
    prov.shutdown
    prov.provisioned?.should.be.false
    registry.first.shutdowns.should == 1
  end

  it "flushes a snapshot at shutdown when snapshot_path is set" do
    Dir.mktmpdir do |dir|
      prov, registry = build_provisioner(snapshot_path: File.join(dir, "snap.marshal"))
      prov.execute("x = 1")
      prov.shutdown
      registry.first.executed.last.should.include "snapshot_state"
      registry.first.executed.last.should.include "snap.marshal"
    end
  end

  it "debounces auto-snapshots after ok executes" do
    Dir.mktmpdir do |dir|
      prov, registry = build_provisioner(snapshot_path: File.join(dir, "snap.marshal"),
                                         snapshot_debounce: 0.02)
      prov.execute("x = 1")
      prov.execute("x = 2")
      sleep 0.2
      snapshots = registry.first.executed.select { |code| code.include?("snapshot_state") }
      snapshots.length.should == 1 # the two executes coalesced
      prov.shutdown
    end
  end

  it "skips snapshot work entirely without snapshot_path" do
    prov, registry = build_provisioner(bootstrap: nil)
    prov.execute("x = 1")
    sleep 0.05
    prov.shutdown
    registry.first.executed.none? { |code| code.include?("snapshot_state") }.should.be.true
  end
end
