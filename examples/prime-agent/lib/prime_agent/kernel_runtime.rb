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
  #
  # prime-agent's kernel talks to its host over a comm bridge on the Jupyter
  # control channel; iruby's dispatch loop is single-threaded and has no
  # control channel, so the bridge here is a FILE: `refine.run` atomically
  # writes `<local harness dir>/refine_request.json`, which the host's
  # AutoRefine middleware drains at the next turn boundary. Harness CRUD
  # needs no bridge at all — both sides read/write harness_state.json
  # directly with mtime re-sync (exactly like prime-agent's Python store).
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

    # The bootstrap cell executed right after the kernel boots. Paths are
    # interpolated as Ruby literals via #inspect.
    def self.bootstrap_code(harness_store_path:, local_dir:, global_dir:, request_path:, skill_lib_glob: nil,
                            kernel_agents_path: File.expand_path("kernel_agents.rb", __dir__),
                            bundle_gemfile: File.expand_path("../../Gemfile", __dir__))
      <<~RUBY
        load #{File.expand_path(harness_store_path).inspect}
        load #{File.expand_path(__FILE__).inspect}
        load #{File.expand_path(kernel_agents_path).inspect}
        PrimeAgent::KernelRuntime.install!(
          harness_store_path: #{File.expand_path(harness_store_path).inspect},
          local_dir: #{local_dir.inspect},
          global_dir: #{global_dir.inspect},
          request_path: #{request_path.inspect},
          skill_lib_glob: #{skill_lib_glob.inspect},
          kernel_agents_path: #{File.expand_path(kernel_agents_path).inspect},
          bundle_gemfile: #{bundle_gemfile.inspect}
        )
        "prime-agent kernel runtime ready"
      RUBY
    end

    def self.install!(local_dir:, global_dir:, request_path:, harness_store_path:, skill_lib_glob: nil,
                      kernel_agents_path: nil, bundle_gemfile: nil)
      load harness_store_path unless defined?(PrimeAgent::HarnessStore)

      harness = PrimeAgent::Harness.new(
        local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
        global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
      )
      refine = RefineProxy.new(request_path: request_path)

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
