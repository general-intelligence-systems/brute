# frozen_string_literal: true

# RuntimeEvents — picoclaw's runtime event bus (pkg/events/, kinds in
# pkg/events/kind.go; logging subscriber in pkg/agent/runtime_event_logger.go).
#
# Owns the turn-span event stream: emits agent.turn.start/end, llm.request/
# response, tool.exec_start/end, steering.injected, context.compress… and fans
# out to subscribers (logging first; later the hooks observer fan-out and the
# evolution bridge's turn.end feed). Config: events.logging.{enabled(true),
# include(["agent.*"]), min_severity("info")}.
#
# env reads: whole env (observes on the unwind). env writes: env[:events]
# subscriber handles. Side effects: log lines.
# Scaffold: pass-through.
class RuntimeEvents
  def initialize(app, **_opts)
    @app = app
  end

  def call(env)
    @app.call(env)
  end
end
