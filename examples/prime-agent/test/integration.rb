#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration: boots a real IRuby kernel and exercises the manager (stage 1)
# and the in-kernel harness/refine runtime (stage 3). Needs the example
# bundle (iruby + omq + libzmq for the kernel's own ffi-rzmq), so it is NOT
# a scampi spec — run it through the flake:
#
#   nix develop ./examples/prime-agent --command ruby examples/prime-agent/test/integration.rb
#   # or from this directory:
#   nix develop --command ruby test/integration.rb

require "fileutils"
require "json"
require "tmpdir"

require "brute"

require_relative "../lib/prime_agent/kernel_manager"
require_relative "../lib/prime_agent/kernel_provisioner"
require_relative "../lib/prime_agent/kernel_runtime"
require_relative "../lib/prime_agent/harness_store"
require_relative "../lib/prime_agent/refinement"
require_relative "../lib/prime_agent/refiner"
require_relative "../lib/prime_agent/iruby_tool"
require_relative "../lib/prime_agent/middleware/kernel_lifecycle"
require_relative "../lib/prime_agent/middleware/harness_prompt"
require_relative "../lib/prime_agent/middleware/auto_refine"
require_relative "../lib/prime_agent/middleware/refine_on_exit"

$stdout.sync = true

def assert(condition, message)
  raise "ASSERTION FAILED: #{message}" unless condition

  puts "ok - #{message}"
end

manager = PrimeAgent::KernelManager.new(cwd: Dir.pwd)
manager.start
assert true, "kernel boots and answers the kernel_info probe"
assert manager.running?, "kernel process is alive after boot"

# State persists across cells — the whole point of the persistent kernel.
manager.execute("meaning_of_life = 41")
result = manager.execute("meaning_of_life + 1")
assert result.status == "ok", "plain cell executes with status ok"
assert result.result == "42", "state persists across cells (got #{result.result.inspect})"

# Methods and constants persist too (IRB workspace semantics).
manager.execute("def greet(name) = \"hello \#{name}\"\nKERNEL_CONST = 7")
result = manager.execute("greet(KERNEL_CONST.class.name.downcase)")
assert result.result == '"hello integer"', "methods and constants persist (got #{result.result.inspect})"

# stdout/stderr streaming.
result = manager.execute('puts "to stdout"; warn "to stderr"')
assert result.stdout.include?("to stdout"), "stdout streams back"
assert result.stderr.include?("to stderr"), "stderr streams back"

# Shell-out from Ruby (iruby has no %%bash — `system` is the contract).
result = manager.execute('`echo from-the-shell`.strip')
assert result.result == '"from-the-shell"', "shell commands run from Ruby (got #{result.result.inspect})"

# Errors surface as ename/evalue/traceback with status error.
result = manager.execute('raise ArgumentError, "boom"')
assert result.status == "error", "raising cell reports status error"
assert result.error["ename"] == "ArgumentError", "error ename is ArgumentError"
assert result.error["traceback"].any? { |line| line.include?("boom") }, "traceback mentions the message"

# The kernel survives errors — next cell still works.
assert manager.execute("2 * 21").result == "42", "kernel keeps working after an error"

# Output caps.
big = "x" * (PrimeAgent::KernelManager::DEFAULT_MAX_OUTPUT_CHARS + 10_000)
result = manager.execute("puts #{big.inspect}")
assert result.stdout.include?("truncated at"), "stdout is capped with a truncation notice"

manager.shutdown
assert !manager.running?, "kernel shuts down cleanly"

# ---------------------------------------------------------------------------
# Stage 3: the in-kernel harness/refine runtime via the provisioner bootstrap
# ---------------------------------------------------------------------------

Dir.mktmpdir do |work|
  local_dir = File.join(work, ".brute", "harness")
  global_dir = File.join(work, "global-harness")
  request_path = File.join(local_dir, "refine_request.json")

  # A REPL skill on the .brute/skills/*/lib load path.
  skill_lib = File.join(work, ".brute", "skills", "demo", "lib")
  FileUtils.mkdir_p(skill_lib)
  File.write(File.join(skill_lib, "demo_skill.rb"),
             "module DemoSkill\n  def self.hi = \"hi from demo skill\"\nend\n")

  provisioner = PrimeAgent::KernelProvisioner.new(
    cwd: work,
    bootstrap: PrimeAgent::KernelRuntime.bootstrap_code(
      harness_store_path: File.expand_path("../lib/prime_agent/harness_store.rb", __dir__),
      local_dir: local_dir,
      global_dir: global_dir,
      request_path: request_path,
      skill_lib_glob: File.join(work, ".brute", "skills", "*", "lib"),
    ),
  )

  result = provisioner.execute('"boot check"')
  assert result.status == "ok", "stage 3 kernel boots with the runtime bootstrap"

  result = provisioner.execute("harness.create_memory('Integration lesson', 'written from the kernel')")
  assert result.status == "ok", "harness.create_memory works from the kernel"

  state = JSON.parse(File.read(File.join(local_dir, "harness_state.json")))
  entry = state.dig("entries", "memory", "integration_lesson")
  assert !entry.nil?, "kernel-side write landed in the local harness_state.json"
  assert entry["scope"] == "local", "entry is local-scoped"

  result = provisioner.execute(<<~RUBY)
    harness.create_skill(
      "Demo skill",
      "Says hi via DemoSkill.hi",
      reference: { "type" => "ruby", "import" => "demo_skill", "callable" => "DemoSkill.hi" },
      arguments: {},
    )
  RUBY
  assert result.status == "ok", "harness.create_skill with a ruby reference works"

  result = provisioner.execute('require "demo_skill"; DemoSkill.hi')
  assert result.result == '"hi from demo skill"', "skill lib dirs are on the kernel load path"

  result = provisioner.execute("harness.overview")
  assert result.result.include?("integration_lesson"), "harness.overview sees the kernel-written entry"

  result = provisioner.execute("get_harness_state.class.name")
  assert result.result.include?("HarnessStore"), "get_harness_state returns the local store"

  provisioner.execute('harness.create_memory("Global lesson", "cross-session", global_: true)')
  global_state = JSON.parse(File.read(File.join(global_dir, "harness_state.json")))
  assert !global_state.dig("entries", "memory", "global_lesson").nil?,
         "global_: true routes to the global store"

  provisioner.execute('refine.run("distill the demo lesson")')
  request = JSON.parse(File.read(request_path))
  assert request["instructions"] == "distill the demo lesson", "refine.run wrote the request file"
  assert request["global"] == false, "request defaults to local scope"

  # ------------------------------------------------------------------
  # Stage 5: KernelAgents — a real brute agent pipeline in the kernel,
  # driven by a scripted terminal (no network).
  # ------------------------------------------------------------------

  provisioner.execute(<<~RUBY)
    PrimeAgent::KernelAgents.terminal = lambda do |env|
      if env[:messages].none? { |m| m.role == :tool }
        env[:messages] << Brute::Message.new(role: :assistant, content: "", tool_calls: [
          { id: "c1", name: "iruby",
            arguments: { "code" => "harness.create_memory('Child lesson', 'from the kernel agent')" } },
        ])
      else
        env[:messages] << Brute::Message.new(role: :assistant, content: "child final answer")
      end
      env
    end
  RUBY

  result = provisioner.execute('KernelAgent.spawn("research task", name: "researcher").inspect')
  assert result.result.include?("KernelAgent researcher"), "spawn returns a handle immediately (got #{result.result})"
  assert !result.result.include?("child final answer"), "admission never returns the child's answer"

  result = provisioner.execute('sleep 3; KernelAgent.finished.map(&:name)')
  assert result.result.include?("researcher"), "child agent finished (got #{result.result})"

  result = provisioner.execute('KernelAgent.get("researcher").result')
  assert result.result == '"child final answer"', "child's final message is its reply (got #{result.result})"

  state = JSON.parse(File.read(File.join(local_dir, "harness_state.json")))
  assert !state.dig("entries", "memory", "child_lesson").nil?,
         "the child's harness write landed in the shared harness_state.json"

  result = provisioner.execute("KernelAgent.list.map(&:name)")
  assert result.result.include?("researcher"), "KernelAgent.list recovers handles"

  provisioner.shutdown
  assert true, "stage 3 kernel shuts down"
end

puts "\nstage 1 + 3 + 5 integration: all assertions passed"

# ---------------------------------------------------------------------------
# Stages 2-4: a full agent run — scripted model (no network), real kernel,
# real harness, real refine passes at the turn boundary and on exit.
# ---------------------------------------------------------------------------

Dir.mktmpdir do |work|
  local_dir = File.join(work, ".brute", "harness")
  global_dir = File.join(work, "global-harness")

  harness = PrimeAgent::Harness.new(
    local_store: PrimeAgent::HarnessStore.new(local_dir, scope: "local"),
    global_store: PrimeAgent::HarnessStore.new(global_dir, scope: "global"),
  )

  refine_calls = []
  refine_llm = lambda do |system:, user:, max_tokens:|
    refine_calls << user
    if refine_calls.length == 1
      JSON.generate({
        summary: "save the distilled lesson",
        rationale: "the trajectory showed it",
        expectedOutcome: "future runs know",
        edits: [{ action: "create", kind: "memory", title: "Distilled lesson",
                  content: "distilled by refine" }],
      })
    else
      %q({"summary": "nothing new", "edits": []})
    end
  end
  refiner = PrimeAgent::Refiner.new(harness: harness, llm: refine_llm)

  provisioner = PrimeAgent::KernelProvisioner.new(
    cwd: work,
    bootstrap: PrimeAgent::KernelRuntime.bootstrap_code(
      harness_store_path: File.expand_path("../lib/prime_agent/harness_store.rb", __dir__),
      local_dir: local_dir,
      global_dir: global_dir,
      request_path: refiner.request_path,
      skill_lib_glob: nil,
    ),
  )

  # The scripted model: one batch of two iruby calls (kernel memory write +
  # refine.run request), then a final answer.
  scripted_model = lambda do |env|
    if env[:messages].none? { |m| m.role == :tool }
      env[:messages] << Brute::Message.new(role: :assistant, content: "kernel time", tool_calls: [
        { id: "t1", name: "iruby",
          arguments: { "code" => "harness.create_memory('Kernel lesson', 'written mid-run')" } },
        { id: "t2", name: "iruby", arguments: { "code" => "refine.run('distill the lesson')" } },
      ])
    else
      env[:messages] << Brute::Message.new(role: :assistant, content: "final answer")
    end
    env
  end

  system_prompt = Brute::SystemPrompt.build { |prompt, _ctx| prompt << "You are a test agent." }

  agent = Brute.agent
    .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
    .use(PrimeAgent::Middleware::RefineOnExit, refiner: refiner)
    .use(Brute::Middleware::SystemPrompt, system_prompt: system_prompt)
    .use(Brute::Middleware::Loop::ToolResult)
    .use(PrimeAgent::Middleware::HarnessPrompt, harness: harness)
    .use(Brute::Middleware::MaxIterations)
    .use(PrimeAgent::Middleware::AutoRefine, refiner: refiner)
    .use(Brute::Middleware::ToolPipeline, tools: [PrimeAgent::IrubyTool.new(provisioner: provisioner)])
    .run(scripted_model)

  env = agent.start("demo task")

  state = JSON.parse(File.read(File.join(local_dir, "harness_state.json")))
  memories = state.fetch("entries").fetch("memory")
  assert memories.key?("kernel_lesson"), "kernel-written memory persisted through the tool pipeline"
  assert memories.key?("distilled_lesson"), "refine.run request was drained and applied at the turn boundary"
  assert refine_calls.length == 2, "refine ran at the turn boundary AND on exit (#{refine_calls.length} calls)"
  assert refine_calls.last.include?("The session is ending"), "the exit refine used the distill instructions"
  assert state["refinements"].length == 2, "both refinement events recorded"

  system_message = env[:messages].find { |m| m.role == :system }.content
  assert system_message.include?("# Continual Harness State"), "harness block injected into the system prompt"
  assert system_message.include?("[local:kernel_lesson]"), "harness block refreshed mid-run with the kernel write"
  assert system_message.include?("[local:distilled_lesson]"), "harness block refreshed with the refined entry"
  assert env[:messages].last.content == "final answer", "agent produced the final answer"
  assert !provisioner.provisioned?, "KernelLifecycle shut the kernel down on exit"
end

puts "\nfull agent run (stages 1-4): all assertions passed"
