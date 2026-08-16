#!/usr/bin/env ruby
# frozen_string_literal: true

# hermes — Hermes Agent (github.com/nousresearch/hermes-agent) ported to brute,
# middleware-by-middleware. See FEATURES.md + MIDDLEWARE.md.

require "json"
require "open_router"
require "brute"
require "brute/turn/pipeline"

require_relative "middleware/tool"
require_relative "middleware/tool_pipeline"

require_relative "middleware/estop"
require_relative "middleware/error_log"
require_relative "middleware/session_store"
require_relative "middleware/memory"
require_relative "middleware/memory_providers"
require_relative "middleware/skills"
require_relative "middleware/todo"
require_relative "middleware/nudge"
require_relative "middleware/prompt_tiers"
require_relative "middleware/session_search"
require_relative "middleware/context_engine"
require_relative "middleware/clarify"
require_relative "middleware/delegation"
require_relative "middleware/process_registry"
require_relative "middleware/cron_schedule"
require_relative "middleware/heartbeat"
require_relative "middleware/curator"
require_relative "middleware/evolution_log"
require_relative "middleware/interrupt"
require_relative "middleware/steering"
require_relative "middleware/iteration_budget"
require_relative "middleware/compaction"
require_relative "middleware/error_recovery"
require_relative "middleware/token_usage"
require_relative "middleware/usage_audit"

require_relative "memory_store"
require_relative "skill_store"
require_relative "write_approval"
require_relative "review"
require_relative "compactor"
require_relative "cron"
require_relative "cron_store"
require_relative "heartbeat"

Dir[File.join(__dir__, "tools", "*.rb")].sort.each { |f| require f }

OpenRouter.configure { |config| config.access_token = ENV.fetch("OPENROUTER_API_KEY") }

tools = HermesTools.constants.map { |c| HermesTools.const_get(c) }.select { |k| k.is_a?(Class) && k < Brute::Tool }.map(&:new)
advertised = Brute.tools(tools).values.map { |a| { type: "function", function: a.to_h } }

# The per-call tool middleware stack (MIDDLEWARE.md §4) — every tool call is
# dispatched through this pipeline by Hermes::Middleware::ToolPipeline.
# Literal `use` list; order is load-bearing (§6).
tool_pipeline = Brute::Turn::Pipeline.new do
  use Hermes::Middleware::Tool::CoerceArgs
  use Hermes::Middleware::Tool::AvailabilityGate
  use Hermes::Middleware::Tool::SafetyGuard
  use Hermes::Middleware::Tool::EditApproval
  use Hermes::Middleware::Tool::Approval
  use Hermes::Middleware::Tool::ReadLoopGuard
  use Hermes::Middleware::Tool::TransformResult
  use Hermes::Middleware::Tool::Audit
  use Hermes::Middleware::Tool::ResultCaps
  use Hermes::Middleware::Tool::SecretRedact
  use Hermes::Middleware::Tool::ResultNormalize
  use Hermes::Middleware::Tool::ErrorWrap
end

# The terminal LLM call. env[:tool_free] (set by IterationBudget's grace call)
# drops tool advertising; env[:model] lets ErrorRecovery switch models.
terminal = lambda do |env|
  options = env[:tool_free] ? {} : { tools: advertised }
  model = env[:model] || ENV["HERMES_MODEL"]
  options[:model] = model if model
  Brute::Middleware::OpenRouter::Completion.new({}, **options).call(env)
end

# One-off LLM call for the Compactor — no tools, no middleware (the aux
# summarizer; hermes' auxiliary.compression route).
summarizer = lambda do |prompt|
  env = Brute.agent.run(terminal).start(prompt)
  env[:messages].select { |m| m.role == :assistant }.last&.content.to_s
end
compactor = Hermes::Compactor.new(
  context_length: (ENV["HERMES_CONTEXT_LENGTH"] || 128_000).to_i,
  summarize: summarizer,
)

# The learning loop: a second Brute.agent run right after the first, with only
# the memory + skill tools and no session logging (BackgroundReview drives it).
review_agent = ->(prompt:, history:) do
  memory_store = Hermes::MemoryStore.new(dir: File.join(Dir.pwd, "memory")).load_from_disk
  skill_store = Hermes::SkillStore.new(dirs: [File.join(Dir.pwd, "skills")])
  review_tools = [HermesTools::Memory.new(memory_store), HermesTools::SkillManage.new(skill_store)]
  review_advertised = Brute.tools(review_tools).values.map { |a| { type: "function", function: a.to_h } }
  options = { tools: review_advertised }
  options[:model] = ENV["HERMES_MODEL"] if ENV["HERMES_MODEL"]

  Brute.agent
    .use(Brute::Middleware::Loop::ToolResult)
    .use(Brute::Middleware::MaxIterations, max_iterations: 16)
    .use(Hermes::Middleware::ToolPipeline, tools: review_tools, pipeline: tool_pipeline)
    .run(Brute::Middleware::OpenRouter::Completion.new({}, **options))
    .start(history + [Brute::Message.new(role: :user, content: prompt)])
end

agent = Brute.agent
  # ── per-turn (MIDDLEWARE.md §2) ─────────────────────────────
  .use(Hermes::Middleware::Estop)
  .use(Hermes::Middleware::ErrorLog)
  .use(Hermes::Middleware::SessionStore)
  .use(Brute::Middleware::SessionLog, path: File.join(Dir.pwd, "sessions", "hermes.jsonl"))
  .use(Hermes::Middleware::Memory)
  .use(Hermes::Middleware::MemoryProviders)
  .use(Hermes::Middleware::Skills)
  .use(Hermes::Middleware::Todo)
  .use(Hermes::Middleware::PromptTiers, tools: tools, model: ENV["HERMES_MODEL"])
  .use(Hermes::Middleware::SessionSearch)
  .use(Hermes::Middleware::ContextEngine)
  .use(Hermes::Middleware::Clarify)
  .use(Hermes::Middleware::Delegation)
  .use(Hermes::Middleware::ProcessRegistry)
  .use(Hermes::Middleware::CronSchedule)
  .use(Hermes::Middleware::Heartbeat)
  .use(Hermes::Middleware::Curator)
  .use(Hermes::Middleware::EvolutionLog)
  .use(Hermes::Middleware::Nudge, state_path: File.join(Dir.pwd, "sessions", "nudge.json"))
  # ── the loop ────────────────────────────────────────────────
  .use(Brute::Middleware::Loop::ToolResult)
  # ── per-iteration (MIDDLEWARE.md §3) ────────────────────────
  .use(Hermes::Middleware::Interrupt)
  .use(Hermes::Middleware::Steering)
  .use(Hermes::Middleware::IterationBudget, max_iterations: 90)
  .use(Hermes::Middleware::Compaction, compactor: compactor)
  .use(Hermes::Middleware::ToolPipeline, tools: tools, pipeline: tool_pipeline)
  .use(Hermes::Middleware::ErrorRecovery, compactor: compactor, fallback_model: ENV["HERMES_FALLBACK_MODEL"])
  .use(Hermes::Middleware::TokenUsage)
  .use(Hermes::Middleware::UsageAudit)
  .run(terminal)

# The cron job runner: a mini Brute.agent per job with the cron policy
# (no memory/clarify/cronjob/todo), the inactivity watchdog, and delivery.
cron_runner = lambda do |job|
  output = +""
  if job["script"] && !job["script"].empty?
    out = Dir.chdir(job["workdir"] || Dir.pwd) { `#{job["script"]}` rescue "script failed: #{$!}" }
    output << out
    unless job["no_agent"]
      output = ""
    else
      Hermes::CronStore.new(File.join(Dir.pwd, "cron")).write_output(job_id: job["id"], content: out)
      return { ok: true, output: out }
    end
  end

  upstream = Array(job["context_from"]).filter_map do |parent_id|
    Hermes::CronStore.new(File.join(Dir.pwd, "cron")).last_output(parent_id)&.then { |o| "[Upstream job output]\n#{o[0, 8_000]}" }
  end

  prompt = +""
  prompt << "[Cron job '#{job['name']}' running unattended. Your reply is delivered when the job fires. If there is nothing worth reporting, reply exactly [SILENT].]\n\n"
  prompt << output << "\n" unless output.empty?
  prompt << upstream.join("\n\n") << "\n\n" unless upstream.empty?
  prompt << job["prompt"].to_s

  denied = %w[clarify memory cronjob todo]
  job_tools = tools.reject { |t| denied.include?(t.name) }
  job_advertised = Brute.tools(job_tools).values.map { |a| { type: "function", function: a.to_h } }
  job_options = { tools: job_advertised }
  job_options[:model] = ENV["HERMES_MODEL"] if ENV["HERMES_MODEL"]

  job_env = nil
  Hermes::Cron.with_watchdog(events: (events = [])) do
    job_env = Brute.agent
      .use(Brute::Middleware::Loop::ToolResult)
      .use(Hermes::Middleware::IterationBudget, max_iterations: 90)
      .use(Hermes::Middleware::ToolPipeline, tools: job_tools, pipeline: tool_pipeline)
      .use(Hermes::Middleware::ErrorRecovery, compactor: compactor, fallback_model: ENV["HERMES_FALLBACK_MODEL"])
      .use(Hermes::Middleware::TokenUsage)
      .run(terminal)
      .start(prompt)
  end

  reply = job_env[:messages].select { |m| m.role == :assistant }.last&.content.to_s
  return { ok: true } if reply.strip.match?(/\A\[?SILENT\]?/i) # [SILENT] suppresses delivery

  store = Hermes::CronStore.new(File.join(Dir.pwd, "cron"))
  path = store.write_output(job_id: job["id"], content: reply)
  puts "Cronjob Response: #{job['name']}\n(job_id: #{job['id']})\n-------------\n\n#{reply}\n\nTo stop or manage this job, send me a new message (e.g. \"stop reminder #{job['name']}\")."
  { ok: true, output_path: path, output: reply }
rescue StandardError => e
  { ok: false, error: "#{e.class}: #{e.message}" }
end

def reply(env)
  env[:messages].select { |m| m.role == :assistant && !m.content.to_s.strip.empty? }.last&.content.to_s
end

if ARGV.empty?
  # Bare invocation = the tick (systemd timer): estop → cron due jobs → heartbeat.
  result = Hermes::Cron.tick(
    store: Hermes::CronStore.new(File.join(Dir.pwd, "cron")),
    run_job: cron_runner,
  )
  result["fired"]&.each { |f| warn "cron: fired #{f['name']} (#{f['status']})" }

  if Hermes::Heartbeat.due?(dir: Dir.pwd)
    heartbeat_env = agent.start(Hermes::Heartbeat.message(Hermes::Heartbeat.load(dir: Dir.pwd)))
    Hermes::Heartbeat.fired!(dir: Dir.pwd)
    puts reply(heartbeat_env)
  end
  exit 0
end

env = agent.start(ARGV.join(" "))
puts reply(env)

# The learning loop: when a nudge fired this turn, the review runs right here —
# a second Brute.agent after the first, with only the memory/skill tools and no
# session log. Writes land in the stores; the summary goes to the user, never
# back into the conversation.
if (env[:review_memory] || env[:review_skills]) && !env[:should_exit]
  Hermes::WriteApproval.current_origin = "background_review"
  begin
    review_env = review_agent.call(
      prompt: Hermes::Review.select_prompt(review_memory: env[:review_memory], review_skills: env[:review_skills]),
      history: env[:messages].to_a,
    )
  ensure
    Hermes::WriteApproval.current_origin = "foreground"
  end

  actions = Hermes::Review.summarize(review_env[:messages], from: env[:messages].size + 1)
  puts "💾 Self-improvement review: #{actions.uniq.join(' · ')}" unless actions.empty?
end
