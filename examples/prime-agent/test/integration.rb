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

# Prefer the repo checkout — Brute::PromptTemplate predates the next release.
repo_lib = File.expand_path("../../../lib", __dir__)
$LOAD_PATH.unshift(repo_lib) if File.directory?(File.join(repo_lib, "brute"))

require "brute"

require_relative "../lib/prime_agent/kernel_manager"
require_relative "../lib/prime_agent/kernel_provisioner"
require_relative "../lib/prime_agent/kernel_runtime"
require_relative "../lib/prime_agent/harness_store"
require_relative "../lib/prime_agent/harness_format"
require_relative "../lib/prime_agent/refinement"
require_relative "../lib/prime_agent/refiner"
require_relative "../lib/prime_agent/iruby_tool"
require_relative "../lib/prime_agent/middleware/kernel_lifecycle"
require_relative "../lib/prime_agent/middleware/prompt_template"
require_relative "../lib/prime_agent/middleware/auto_refine"
require_relative "../lib/prime_agent/middleware/refine_on_exit"
require_relative "../lib/prime_agent/middleware/compaction"
require_relative "../lib/prime_agent/middleware/goal"
require_relative "../lib/prime_agent/middleware/autonomous"
require_relative "../lib/prime_agent/cron_store"
require_relative "../lib/prime_agent/schedule_driver"
require_relative "../lib/prime_agent/goal"

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

  # The shipped edit skill: Edit.run edits the file AND emits the diff
  # display over display_data, captured by the manager onto result.diffs
  # (prime-agent's KernelDiffDisplay side channel, kernel/index.ts:1096-1108).
  FileUtils.cp(File.expand_path("../work/.brute/skills/edit/lib/edit.rb", __dir__), skill_lib)
  edit_target = File.join(work, "edit-target.txt")
  File.write(edit_target, "alpha\nbeta\ngamma\n")
  result = provisioner.execute(<<~RUBY)
    require "edit"
    Edit.run(path: #{edit_target.inspect}, old_str: "beta", new_str: "BETA")
  RUBY
  assert result.status == "ok", "Edit.run executes in the kernel"
  assert result.result.include?("Edited #{edit_target}"), "Edit.run returns the confirmation (got #{result.result})"
  assert File.read(edit_target).include?("BETA"), "the file was actually edited"
  diff = result.diffs.find { |d| d["path"] == edit_target }
  assert diff, "the diff display was captured onto the cell result"
  assert diff["old_str"] == "beta" && diff["new_str"] == "BETA", "the diff payload carries old/new strings"
  assert diff["start_line"] == 2, "the diff payload carries the 1-based start line"

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

  # Stage 7 (kernel side): the `compact` proxy rides request/status files in
  # the local harness dir.
  result = provisioner.execute('compact.run("keep the migration checklist")')
  assert result.result.include?('"scheduled" => true'), "compact.run schedules (got #{result.result})"
  compact_request = JSON.parse(File.read(File.join(local_dir, "compact_request.json")))
  assert compact_request["instructions"] == "keep the migration checklist", "compact.run wrote the request file"
  result = provisioner.execute("compact.status")
  assert result.result.include?('"scheduled" => true'), "compact.status sees the pending request"
  result = provisioner.execute("begin; compact.run(42); rescue TypeError => e; e.class.name; end")
  assert result.result.include?("TypeError"), "compact.run validates instructions"

  # Stage 8 (kernel side): the rlm_heartbeat proxy writes the shared job
  # store directly from the kernel.
  result = provisioner.execute(<<~RUBY)
    hb = rlm_heartbeat.create("check the test run", interval: "5m", label: "tests")
    rlm_heartbeat.update(hb["id"], status: "pause")
    [rlm_heartbeat.list.length, rlm_heartbeat.list(include_inactive: true).length]
  RUBY
  assert result.result.include?("0") && result.result.include?("1"),
         "rlm_heartbeat create/update/list works from the kernel (got #{result.result})"
  cron_state = JSON.parse(File.read(File.join(local_dir, "scheduled-jobs.json")))
  heartbeat_job = cron_state["jobs"].find { |j| j["source"] == "rlm_heartbeat" }
  assert heartbeat_job, "the kernel-created heartbeat landed in the job store"
  assert heartbeat_job["status"] == "paused", "the pause update landed"
  assert heartbeat_job["schedule"]["interval_seconds"] == 300, "the 5m interval parsed"
  assert heartbeat_job["label"] == "tests", "the label landed"

  # Stage 9 (kernel side): the goal proxy validates, schedules, and reads back.
  result = provisioner.execute("goal.get")
  assert result.result.include?('"goal" => nil'), "goal.get starts empty (got #{result.result})"
  result = provisioner.execute(<<~RUBY)
    goal.create("ship the release", token_budget: 50000)
    [goal.get["goal"].nil?, goal.get["remaining_tokens"]]
  RUBY
  assert result.result.include?("true"), "goal.create defers to the turn boundary (got #{result.result})"
  goal_request = JSON.parse(File.read(File.join(local_dir, "goal_request.json")))
  assert goal_request["action"] == "create", "goal.create wrote the request file"
  assert goal_request["token_budget"] == 50_000, "the budget landed"
  result = provisioner.execute("begin; goal.create(42); rescue TypeError => e; e.class.name; end")
  assert result.result.include?("TypeError"), "goal.create validates the objective type"

  # Stage 6 (kernel side): Edit.run serializes same-file mutations across
  # threads (the port of prime-agent's withFileMutationQueue).
  queue_target = File.join(work, "queue-target.txt")
  File.write(queue_target, "0")
  result = provisioner.execute(<<~RUBY)
    threads = 8.times.map do |i|
      Thread.new do
        5.times do
          Edit::MutationQueue.serialize(#{queue_target.inspect}) do
            current = File.read(#{queue_target.inspect}).to_i
            sleep 0.001 # force a scheduling point mid read-modify-write
            File.write(#{queue_target.inspect}, (current + 1).to_s)
          end
        end
      end
    end
    threads.each(&:join)
    File.read(#{queue_target.inspect})
  RUBY
  assert result.result.include?('"40"'), "same-file mutations serialize (got #{result.result})"
  result = provisioner.execute("Edit::MutationQueue.size")
  assert result.result.include?("0"), "mutation queue self-cleans (got #{result.result})"

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
# Stage 7: compaction — a kernel `compact.run` request is drained at the turn
# boundary through a full agent run (scripted model, real kernel).
# ---------------------------------------------------------------------------

Dir.mktmpdir do |work|
  local_dir = File.join(work, ".brute", "harness")
  FileUtils.mkdir_p(local_dir)
  request_path = File.join(local_dir, "compact_request.json")
  status_path = File.join(local_dir, "compact_status.json")
  File.write(request_path, JSON.generate("instructions" => "keep the failing tests"))

  summary_prompts = []
  compact_llm = lambda do |system:, user:, max_tokens:|
    summary_prompts << user
    "stage-7 summary"
  end

  provisioner = PrimeAgent::KernelProvisioner.new(
    cwd: work,
    bootstrap: PrimeAgent::KernelRuntime.bootstrap_code(
      harness_store_path: File.expand_path("../lib/prime_agent/harness_store.rb", __dir__),
      local_dir: local_dir,
      global_dir: File.join(work, "global-harness"),
      request_path: File.join(local_dir, "refine_request.json"),
      skill_lib_glob: nil,
    ),
  )

  scripted_model = lambda do |env|
    if env[:messages].none? { |m| m.role == :tool }
      env[:messages] << Brute::Message.new(role: :assistant, content: "", tool_calls: [
        { id: "c1", name: "iruby", arguments: { "code" => "'#{"x" * 2000}'" } },
      ])
    else
      env[:messages] << Brute::Message.new(role: :assistant, content: "done")
    end
    env
  end

  agent = Brute.agent
    .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
    .use(Brute::Middleware::Loop::ToolResult)
    .use(Brute::Middleware::MaxIterations)
    .use(PrimeAgent::Middleware::Compaction,
         llm: compact_llm,
         context_window: nil, # threshold disabled — only the request fires
         keep_recent_tokens: 10,
         reserve_tokens: 50,
         request_path: request_path,
         status_path: status_path)
    .use(Brute::Middleware::ToolPipeline, tools: [PrimeAgent::IrubyTool.new(provisioner: provisioner)])
    .run(scripted_model)

  env = agent.start("long task")

  assert !File.exist?(request_path), "the compact request was drained"
  summary = env[:messages].find { |m| m.content.to_s.include?("compacted into the following summary") }
  assert summary, "the compaction summary message was injected"
  assert summary.role == :user, "the summary is a user message"
  assert summary.content.include?("stage-7 summary"), "the scripted summary landed"
  assert summary.content.include?("**Turn Context (split turn):**"), "mid-turn cut produced a turn-prefix summary"
  assert env[:messages].none? { |m| m.content.to_s.include?("x" * 100) }, "the summarized region is gone"
  assert env[:messages].last.content == "done", "the final answer survives compaction"
  status = JSON.parse(File.read(status_path))
  assert status["scheduled"] == false, "compact.status shows the drained request"
  assert status["percent"].nil?, "percent is null right after a compaction"
end

puts "\nstage 7 integration (compaction): all assertions passed"

# ---------------------------------------------------------------------------
# Stage 8: scheduled prompts — a due job claimed from the store is delivered
# as a fresh agent run (scripted model, real kernel per run).
# ---------------------------------------------------------------------------

Dir.mktmpdir do |work|
  local_dir = File.join(work, ".brute", "harness")
  store = PrimeAgent::CronStore.new(File.join(local_dir, "scheduled-jobs.json"))
  store.create(prompt: "the scheduled prompt", schedule_text: "in 30m", now: Time.utc(2020, 1, 1))
  store.create_heartbeat(instruction: "check the deployment", now: Time.utc(2020, 1, 1))

  tasks = []
  build_agent = lambda do
    provisioner = PrimeAgent::KernelProvisioner.new(
      cwd: work,
      bootstrap: PrimeAgent::KernelRuntime.bootstrap_code(
        harness_store_path: File.expand_path("../lib/prime_agent/harness_store.rb", __dir__),
        local_dir: local_dir,
        global_dir: File.join(work, "global-harness"),
        request_path: File.join(local_dir, "refine_request.json"),
        skill_lib_glob: nil,
      ),
    )
    scripted_model = lambda do |env|
      tasks << env[:messages].reverse.find { |m| m.role == :user }&.content
      env[:messages] << Brute::Message.new(role: :assistant, content: "scheduled answer")
      env
    end
    Brute.agent
      .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
      .use(Brute::Middleware::Loop::ToolResult)
      .use(Brute::Middleware::MaxIterations)
      .use(Brute::Middleware::ToolPipeline, tools: [PrimeAgent::IrubyTool.new(provisioner: provisioner)])
      .run(scripted_model)
  end

  PrimeAgent::ScheduleDriver.new(store: store, agent_factory: build_agent).run(nil)

  assert tasks.include?("the scheduled prompt"), "the due cron job ran as an agent task"
  assert tasks.include?("check the deployment"), "the due heartbeat ran as an agent task"
  cron_job = store.jobs.find { |j| j.prompt == "the scheduled prompt" }
  assert cron_job.run_count == 1 && cron_job.status == "completed", "the one-shot completed"
  heartbeat = store.jobs.find { |j| j.source == "heartbeat" }
  assert heartbeat.run_count == 1 && heartbeat.status == "active", "the heartbeat stays active for the next tick"
  assert heartbeat.next_run_at, "the heartbeat's next tick was advanced at claim time"
end

puts "\nstage 8 integration (scheduled prompts + heartbeats): all assertions passed"

# ---------------------------------------------------------------------------
# Stage 9: goals + autonomous — a seeded goal re-prompts across turns until
# the kernel's goal.complete lands; autonomous continuations respect limits.
# ---------------------------------------------------------------------------

Dir.mktmpdir do |work|
  local_dir = File.join(work, ".brute", "harness")
  goal_path = File.join(local_dir, "goal.json")
  PrimeAgent::Goal.create_in_store(goal_path, objective: "ship the integration test", token_budget: 1_000_000)

  provisioner = PrimeAgent::KernelProvisioner.new(
    cwd: work,
    bootstrap: PrimeAgent::KernelRuntime.bootstrap_code(
      harness_store_path: File.expand_path("../lib/prime_agent/harness_store.rb", __dir__),
      local_dir: local_dir,
      global_dir: File.join(work, "global-harness"),
      request_path: File.join(local_dir, "refine_request.json"),
      skill_lib_glob: nil,
    ),
  )

  scripted_model = lambda do |env|
    if env[:messages].last&.role == :tool
      env[:messages] << Brute::Message.new(role: :assistant, content: "noted")
      next env
    end
    contexts = env[:messages].count { |m| m.content.to_s.include?("<goal_context>") }
    if contexts.zero?
      env[:messages] << Brute::Message.new(role: :assistant, content: "", tool_calls: [
        { id: "g1", name: "iruby", arguments: { "code" => 'goal.get["goal"]["status"]' } },
      ])
    elsif contexts == 1
      env[:messages] << Brute::Message.new(role: :assistant, content: "", tool_calls: [
        { id: "g2", name: "iruby", arguments: { "code" => "goal.complete" } },
      ])
    else
      env[:messages] << Brute::Message.new(role: :assistant, content: "goal work done")
    end
    env
  end

  agent = Brute.agent
    .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
    .use(PrimeAgent::Middleware::Goal,
         store_path: goal_path,
         request_path: File.join(local_dir, "goal_request.json"))
    .use(PrimeAgent::Middleware::Autonomous, enabled: true, cwd: work,
         goal_store_path: goal_path, max_continuations: 5)
    .use(Brute::Middleware::Loop::ToolResult)
    .use(Brute::Middleware::MaxIterations)
    .use(Brute::Middleware::ToolPipeline, tools: [PrimeAgent::IrubyTool.new(provisioner: provisioner)])
    .run(scripted_model)

  env = agent.start("do the goal")

  contexts = env[:messages].select { |m| m.content.to_s.include?("<goal_context>") }
  assert contexts.length == 1, "exactly one goal continuation was injected (got #{contexts.length})"
  assert contexts.first.role == :user, "the continuation is a user message"
  assert contexts.first.content.include?("ship the integration test"), "the objective is in the context"
  assert env[:messages].any? { |m| m.role == :tool && m.content.to_s.include?("active") },
         "goal.get saw the active goal from the kernel"
  state = PrimeAgent::Goal.load_state(goal_path)
  assert state.status == "complete", "goal.complete drained and marked the goal complete"
  assert state.continuations_used == 1, "the continuation was accounted (got #{state.continuations_used})"
  assert state.tokens_used > 0, "estimated usage was accounted"
  # Autonomous deferred the whole time: no autonomous continuation messages.
  assert env[:messages].none? { |m| m.content.to_s.include?("autonomous mode") },
         "autonomous deferred to the active goal"
end

Dir.mktmpdir do |work|
  # Autonomous without a goal: continuations up to the limit, then stop.
  calls = 0
  scripted_model = lambda do |env|
    calls += 1
    env[:messages] << Brute::Message.new(role: :assistant, content: "working")
    env
  end
  agent = Brute.agent
    .use(PrimeAgent::Middleware::Autonomous, enabled: true, cwd: work, max_continuations: 2)
    .use(Brute::Middleware::Loop::ToolResult)
    .use(Brute::Middleware::MaxIterations)
    .run(scripted_model)
  env = agent.start("unsupervised task")
  continuations = env[:messages].select { |m| m.content.to_s.include?("No human input is available") }
  assert continuations.length == 2, "autonomous continued exactly to maxContinuations (got #{continuations.length})"
  assert calls == 3, "initial turn + 2 continuations (got #{calls})"
end

puts "\nstage 9 integration (goals + autonomous): all assertions passed"

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

  system_prompt = Brute::PromptTemplate.new(
    "You are a test agent.\n\n<%= harness_state %>",
    harness_state: -> { PrimeAgent::HarnessFormat.format_harness_state_for_prompt(harness.merged_state) },
  )

  agent = Brute.agent
    .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
    .use(PrimeAgent::Middleware::RefineOnExit, refiner: refiner)
    .use(Brute::Middleware::Loop::ToolResult)
    .use(PrimeAgent::Middleware::PromptTemplate, prompt: system_prompt)
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
