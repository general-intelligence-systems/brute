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

    def initialize(cwd:, bootstrap: nil, kernel_class: KernelManager)
      @cwd = cwd
      @bootstrap = bootstrap # String, or a callable returning a String
      @kernel_class = kernel_class
      @manager = nil
      @mutex = Mutex.new
    end

    # The running kernel manager, booting + bootstrapping on first use.
    def kernel
      @mutex.synchronize { @manager ||= boot }
    end

    def execute(code, **options)
      kernel.execute(code, **options)
    end

    # Whether the kernel has been provisioned (says nothing about liveness —
    # the manager itself tracks that).
    def provisioned?
      !@manager.nil?
    end

    def shutdown
      @mutex.synchronize do
        @manager&.shutdown
        @manager = nil
      end
      nil
    end

    private

    def boot
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
  end
end

__END__

describe "prime_agent/kernel_provisioner" do
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
                   status: "error", error: { "traceback" => ["tb"] }, duration_ms: 1)
      else
        Result.new(stdout: "ok", stderr: "", result: nil,
                   status: "ok", error: nil, duration_ms: 1)
      end
    end

    def shutdown
      @shutdowns += 1
    end
  end

  # Returns [provisioner, registry-of-created-fake-kernels]. Fresh registry
  # per call — scampi reuses the describe context across `it` blocks.
  def build_provisioner(bootstrap: "BOOTSTRAP", fail_bootstrap: false)
    registry = []
    factory = Class.new(FakeKernel) do
      define_method(:initialize) do |cwd:|
        super(cwd: cwd, fail_bootstrap: fail_bootstrap)
        registry << self
      end
    end
    [PrimeAgent::KernelProvisioner.new(cwd: "/tmp", bootstrap: bootstrap, kernel_class: factory), registry]
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
end
