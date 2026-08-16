# frozen_string_literal: true

require_relative "seahorse/engine"
require_relative "seahorse/retrieval"

# SeahorseContext — the seahorse context manager as middleware (upstream:
# agents.defaults.context_manager == "seahorse" swaps the legacy manager).
# Active when config context_manager == "seahorse"; sits where SessionStore
# sits (SessionStore then runs with read: false — the JSONL log stays as the
# bootstrap/debug surface while the SQLite store owns assembly).
#
# IN : engine.assemble → env[:messages] becomes [assembled history] + [the
#      turn's new messages]; the summary XML goes to
#      env[:metadata][:summary_override] (prompt.erb's summary section).
# OUT: the turn's new messages are ingested into the store; when the context
#      exceeds 75% of the window, compact_until_under runs (leaf + condensed
#      summaries via the LLM).
class SeahorseContext
  def initialize(app, engine:, session:, budget:, window:)
    @app = app
    @engine = engine
    @session = session
    @budget = budget
    @window = window
  end

  def call(env)
    assembled = @engine.assemble(@session, budget: @budget)
    current = env[:messages]
    env[:messages] = assembled[:messages] + current
    env[:metadata][:summary_override] = assembled[:summary] unless assembled[:summary].empty?
    env[:metadata][:seahorse_from] = assembled[:messages].size # turn delta starts after the stored history

    @app.call(env)

    delta = env[:messages].drop(env[:metadata][:seahorse_from] || 0)
    @engine.ingest(@session, delta)
    @engine.compact_until_under(@session, @budget) if @engine.tokens(@session) > @window * 0.75
    env
  end
end
