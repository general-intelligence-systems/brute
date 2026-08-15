# frozen_string_literal: true

# ToolPolicy — picoclaw's per-tool-call policy layer (pkg/agent/
# pipeline_execute.go:111-864, pkg/tools/registry.go:251-362, validate.go).
#
# Final home is a Brute::Turn::ToolPipeline around EACH tool execution (the
# layer WorkspaceGuard/SafetyGuard already hang off as wrappers): turn-profile
# tool allowlist (deny -> synthetic tool error), arg validation against the
# declared JSON schema, panic recovery into error results, sensitive-data
# scrub of results (tools.filter_sensitive_data, min length 8), media delivery
# + ResponseHandled (turn may end on tool output), async results re-entering
# as system-channel turns, and message-tool delivery dedup (suppress the final
# reply when `message` already delivered this round).
#
# env reads: tool calls + results. env writes: tool results, :messages.
# Side effects: delivery/dedup bookkeeping.
# Scaffold: pass-through.
class ToolPolicy
  def initialize(app, **_opts)
    @app = app
  end

  def call(env)
    @app.call(env)
  end
end
