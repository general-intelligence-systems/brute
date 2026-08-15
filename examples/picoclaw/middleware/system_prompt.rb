# frozen_string_literal: true

# SystemPrompt — picoclaw's prompt assembly (pkg/agent/prompt.go, context.go,
# prompt_contributors.go).
#
# Parts model: Layer (kernel > instruction > capability > context > turn) x
# Slot (identity, workspace, tooling, skill_catalog, active_skill, memory,
# output, runtime, summary), joined "\n\n---\n\n". Static block (identity rules
# + AGENT.md/SOUL.md/USER.md + skills catalog + memory) cached and invalidated
# on file mtimes; per-request parts appended: active skill bodies, runtime
# (time/OS/channel), conversation summary. Composition = exactly ONE system
# message. Will absorb Brute::Middleware::SystemPrompt + prompt.erb, which
# currently sit immediately inside it in the stack.
#
# env reads: prompt parts from SkillsCatalog/MemoryFiles, session summary.
# env writes: :messages (prepends the system message). Side effects: file
# reads, mtime watch.
# Scaffold: pass-through.
class SystemPrompt
  def initialize(app, **_opts)
    @app = app
  end

  def call(env)
    @app.call(env)
  end
end
