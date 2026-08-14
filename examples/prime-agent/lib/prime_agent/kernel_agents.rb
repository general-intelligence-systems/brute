# frozen_string_literal: true

require "stringio"
require "time"

module PrimeAgent
  # KernelAgents — recursive child agents that run INSIDE the IRuby kernel.
  #
  # The port of prime-agent's `rlm(...)` subagent callable (docs/rlm-runtime.md)
  # to this port's runtime. prime-agent's host admits a child AgentSession per
  # spawn; here the kernel is just Ruby, so a KernelAgent IS a brute agent —
  # a full `Brute.agent` middleware pipeline (system prompt, tool loop, max
  # iterations, an `iruby` eval tool bound to the child's own binding,
  # OpenRouter completion) running on a thread inside the kernel process.
  #
  # Semantics mirror prime-agent:
  #
  #   handle = KernelAgent.spawn("inspect the API", name: "api-reviewer")
  #
  #  - spawn returns the handle IMMEDIATELY (admission, never completion) —
  #    it never returns the child's answer;
  #  - the parent ends its turn and reads `KernelAgent.finished` on a later
  #    turn; each handle exposes .status/.result/.error;
  #  - children inherit the model, may themselves spawn (recursion depth is
  #    tracked per-thread), and can write files for fan-in;
  #  - harness CRUD and refine.run work in children exactly as in the parent
  #    (shared harness_state.json, shared request file);
  #  - `KernelAgent.stop("name")` kills a child's thread;
  #  - past BRUTE_KERNEL_AGENT_MAX_DEPTH (default 2) spawn returns an error
  #    string instead of starting a thread.
  #
  # This file is loaded into the kernel by the stage-3 bootstrap. brute and
  # open_router are required lazily on first spawn (scoped to the example
  # bundle, see .ensure_loaded!), so this file also loads in the plain repo
  # test suite — specs inject a scripted `.terminal` and never touch a
  # network.
  module KernelAgents
    MAX_ITERATIONS = 25
    TERMINAL_STATUSES = %i[finished failed stopped].freeze

    class Error < StandardError; end

    # The spawn handle. `.result` is nil until a terminal status; on :failed
    # it carries the error text so a polling parent sees what happened.
    class Agent
      attr_reader :id, :name, :task, :depth, :model, :status, :error, :thread

      def initialize(id:, name:, task:, depth:, model:)
        @id = id
        @name = name
        @task = task
        @depth = depth
        @model = model
        @status = :running
        @error = nil
        @result = nil
        @created_at = Time.now.utc.iso8601
      end

      def start!
        @thread = Thread.new do
          Thread.current[:kernel_agent_depth] = @depth
          run
        end
        self
      end

      def alive?
        @status == :running
      end

      def result
        @result
      end

      def stop!
        @thread&.kill
        @status = :stopped
        true
      end

      def inspect
        "#<KernelAgent #{@name} status=#{@status} depth=#{@depth}>"
      end
      alias_method :to_s, :inspect

      private

      def run
        context = Object.new
        child_binding = context.instance_eval { binding }
        system_prompt = Brute::SystemPrompt.build { |prompt, _ctx| prompt << child_prompt }
        agent = Brute.agent
                     .use(Brute::Middleware::SystemPrompt, system_prompt: system_prompt)
                     .use(Brute::Middleware::Loop::ToolResult)
                     .use(Brute::Middleware::MaxIterations, max_iterations: MAX_ITERATIONS)
                     .use(Brute::Middleware::ToolPipeline,
                          tools: [EvalTool.new(eval_binding: child_binding)])
                     .run(KernelAgents.terminal_for(@model))
        env = agent.start(@task)
        final = env[:messages].reverse.find { |message| message.role == :assistant }
        @result = final&.content.to_s
        @status = :finished
      rescue Exception => error # rubocop:disable Lint/RescueException — a child must never kill the kernel
        @error = error
        @result = "KernelAgent #{@name} failed: #{error.class}: #{error.message}"
        @status = :failed
      ensure
        @finished_at = Time.now.utc.iso8601
      end

      def child_prompt
        <<~TXT
          You are a KernelAgent (recursive agent depth #{@depth}) — a child agent running inside the shared IRuby kernel of a prime-agent session.

          You solve the delegated task step by step with the iruby tool: Ruby code runs in your own binding inside the kernel. Parent variables are not visible in your binding; the continual harness (`harness.create_memory(...)` and friends) and `refine.run` are available. You may spawn further KernelAgents with `KernelAgent.spawn("sub-task", name: "...")` while under the depth limit.

          When the task is done, stop calling tools and state your final answer — your final message is delivered to the parent as your reply. Write files for anything large.
        TXT
      end
    end

    # The child's `iruby` tool: evaluate Ruby in the child's binding, with
    # the same result rendering as the host tool (stdout, stderr, result,
    # traceback). Duck-typed (Brute::Tools::Adapter.from_duck_type) so this
    # file loads before brute is available. Output capture swaps
    # $stdout/$stderr under a process-wide mutex — best-effort while the
    # kernel is otherwise busy; children should write files for anything
    # that matters.
    class EvalTool
      DESCRIPTION = <<~TXT.tr("\n", " ").squeeze(" ").freeze
        Execute Ruby code in this KernelAgent's own binding inside the shared IRuby kernel. State persists across your calls; the harness (harness.*) and refine.run are available. Write files for large outputs.
      TXT
      PARAMS = { code: { type: "string", desc: "Ruby code to execute", required: true } }.freeze

      def initialize(eval_binding:)
        @binding = eval_binding
      end

      def name
        "iruby"
      end

      def description
        DESCRIPTION
      end

      def params
        PARAMS
      end

      def execute(code:)
        KernelAgents.capture_eval(@binding, code)
      end
    end

    EVAL_MUTEX = Mutex.new

    class << self
      # Test seam: when set, children run this terminal app instead of the
      # OpenRouter completion middleware.
      attr_accessor :terminal, :bundle_gemfile

      def spawn(task, name: nil, model: nil)
        depth = (Thread.current[:kernel_agent_depth] || 0) + 1
        if depth > max_depth
          return "KernelAgent not spawned: recursive agent depth limit " \
                 "(#{depth} > #{max_depth}). Answer inline instead."
        end

        ensure_loaded!
        agent = nil
        registry_mutex.synchronize do
          agent = Agent.new(id: next_id, name: unique_name(name), task: task, depth: depth, model: model)
          registry[agent.name] = agent
        end
        agent.start!
      end

      def list
        registry_mutex.synchronize { registry.values.dup }
      end

      def running
        list.select(&:alive?)
      end

      def finished
        list.reject(&:alive?)
      end

      def get(name)
        registry_mutex.synchronize { registry[name.to_s] }
      end

      def stop(name)
        agent = get(name)
        return "no KernelAgent named #{name.inspect}" unless agent

        agent.stop!
      end

      def max_depth
        (ENV["BRUTE_KERNEL_AGENT_MAX_DEPTH"] || 2).to_i
      end

      def terminal_for(model)
        return @terminal if @terminal

        ensure_openrouter!
        options = {}
        options[:model] = model || ENV["BRUTE_MODEL"] if model || ENV["BRUTE_MODEL"]
        Brute::Middleware::OpenRouter::Completion.new({}, **options)
      end

      def capture_eval(eval_binding, code)
        EVAL_MUTEX.synchronize do
          out = StringIO.new
          err = StringIO.new
          original_out = $stdout
          original_err = $stderr
          $stdout = out
          $stderr = err
          begin
            value = eval_binding.eval(code)
            text = out.string
            text += "\n#{err.string}" unless err.string.empty?
            text += "\n#{value.inspect}" unless value.nil?
            text
          rescue Exception => error # rubocop:disable Lint/RescueException — tool errors become results
            text = out.string
            text += "\n#{err.string}" unless err.string.empty?
            text += "\n#{error.class}: #{error.message}\n  #{Array(error.backtrace).first(5).join("\n  ")}"
            text
          ensure
            $stdout = original_out
            $stderr = original_err
          end
        end
      end

      # brute/open_router load lazily on first spawn, scoped to the example
      # bundle: the kernel's cwd is the user's project (its own Gemfile
      # must not leak in), so BUNDLE_GEMFILE is pinned for the require and
      # restored afterwards.
      def ensure_loaded!
        return if defined?(Brute)

        previous = ENV["BUNDLE_GEMFILE"]
        ENV["BUNDLE_GEMFILE"] = @bundle_gemfile if @bundle_gemfile
        begin
          require "brute"
        ensure
          previous ? ENV["BUNDLE_GEMFILE"] = previous : ENV.delete("BUNDLE_GEMFILE")
        end
      end

      def ensure_openrouter!
        return if @openrouter_ready

        ensure_loaded!
        previous = ENV["BUNDLE_GEMFILE"]
        ENV["BUNDLE_GEMFILE"] = @bundle_gemfile if @bundle_gemfile
        begin
          require "open_router"
          OpenRouter.configure { |config| config.access_token = ENV["OPENROUTER_API_KEY"] }
        ensure
          previous ? ENV["BUNDLE_GEMFILE"] = previous : ENV.delete("BUNDLE_GEMFILE")
        end
        @openrouter_ready = true
      end

      private

      def registry
        @registry ||= {}
      end

      def registry_mutex
        @registry_mutex ||= Mutex.new
      end

      def next_id
        @counter = (@counter || 0) + 1
        "ka_#{@counter}"
      end

      def unique_name(name)
        base = (name || "agent").to_s
        candidate = base
        suffix = 2
        while registry.key?(candidate)
          candidate = "#{base}-#{suffix}"
          suffix += 1
        end
        candidate
      end
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/kernel_agents" do
  KA = PrimeAgent::KernelAgents

  def spawn_and_wait(task = "do it", name: nil, timeout: 5)
    agent = KA.spawn(task, name: name)
    agent.thread.join(timeout) if agent.is_a?(KA::Agent)
    agent
  end

  it "spawns a real brute agent pipeline and returns the handle immediately" do
    KA.terminal = lambda do |env|
      env[:messages].assistant("child done")
      env
    end
    agent = KA.spawn("test task", name: "tester")
    agent.should.be.kind_of KA::Agent
    %i[running finished].should.include agent.status # admission, never completion
    agent.thread.join(5)
    agent.status.should == :finished
    agent.result.should == "child done"
    agent.inspect.should.include "tester"
  ensure
    KA.terminal = nil
  end

  it "runs the child's iruby tool calls inside the kernel" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "child-was-here")
      calls = 0
      KA.terminal = lambda do |env|
        calls += 1
        if calls == 1
          env[:messages] << Brute::Message.new(role: :assistant, content: "", tool_calls: [
            { id: "e1", name: "iruby", arguments: { "code" => "File.write(#{marker.inspect}, 'x')" } },
          ])
        else
          env[:messages].assistant("wrote the file")
        end
        env
      end
      agent = spawn_and_wait("write a file", name: "writer")
      agent.status.should == :finished
      agent.result.should == "wrote the file"
      File.read(marker).should == "x"
    end
  ensure
    KA.terminal = nil
  end

  it "unique-names siblings" do
    KA.terminal = ->(env) { env[:messages].assistant("ok"); env }
    a = spawn_and_wait("one", name: "same")
    b = spawn_and_wait("two", name: "same")
    a.name.should == "same"
    b.name.should == "same-2"
    KA.get("same-2").should.equal b
  ensure
    KA.terminal = nil
  end

  it "refuses to spawn past the depth limit (error string, no thread)" do
    Thread.current[:kernel_agent_depth] = KA.max_depth
    result = KA.spawn("too deep")
    result.should.be.kind_of String
    result.should.include "depth limit"
  ensure
    Thread.current[:kernel_agent_depth] = nil
  end

  it "tracks running/finished and stops children" do
    KA.terminal = lambda do |env|
      sleep 30
      env
    end
    agent = KA.spawn("slow", name: "slowpoke")
    KA.running.map(&:name).should.include "slowpoke"
    KA.stop("slowpoke")
    agent.thread.join(5)
    agent.status.should == :stopped
    KA.finished.map(&:name).should.include "slowpoke"
    KA.stop("no-such-agent").should.include "no KernelAgent named"
  ensure
    KA.terminal = nil
  end

  it "marks the agent failed (with the error as result) when its loop raises" do
    KA.terminal = ->(_env) { raise "provider exploded" }
    agent = spawn_and_wait("boom", name: "faily")
    agent.status.should == :failed
    agent.result.should.include "provider exploded"
    agent.error.should.not.be.nil
  ensure
    KA.terminal = nil
  end

  it "capture_eval renders stdout, result and errors like the iruby tool" do
    eval_binding = Object.new.instance_eval { binding }
    out = KA.capture_eval(eval_binding, 'puts "hi"; 40 + 2')
    out.should.include "hi"
    out.should.include "42"

    err = KA.capture_eval(eval_binding, 'raise ArgumentError, "bad"')
    err.should.include "ArgumentError: bad"

    KA.capture_eval(eval_binding, "nil").should.not.include "nil"
  end
end
