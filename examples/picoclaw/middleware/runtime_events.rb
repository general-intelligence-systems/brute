# frozen_string_literal: true

# RuntimeEvents — picoclaw's runtime event bus (pkg/events/), port-sized.
#
# The middleware owns the turn-span events (agent.turn.start/end, end fires
# from an ensure); the llm.*/tool.* events come from the gem's .on()
# lifecycle hooks, wired in main.rb through RuntimeEvents.log_to (so the same
# include/exclude/severity filter and logger apply). env[:events] receives
# every event hash (the in-process subscriber feed — the evolution bridge's
# turn.end slot among them).
#
# Config: events.logging.{enabled(true), include(["agent.*"]), exclude([]),
# min_severity("info"), include_payload(false)}.
class RuntimeEvents
  SEVERITIES = %w[debug info warn error].freeze

  class << self
    attr_accessor :current
  end

  # Static emit for the .on() wiring (llm/tool events fired inside the loop).
  def self.emit(kind, payload: {}, severity: "info")
    current&.emit(kind, payload: payload, severity: severity)
  end

  def initialize(app, enabled: true, include: ["agent.*"], exclude: [],
                 min_severity: "info", include_payload: false, logger: nil)
    @app = app
    @enabled = enabled
    @include = include
    @exclude = exclude
    @min_severity = min_severity
    @include_payload = include_payload
    @logger = logger
    self.class.current = self
  end

  def call(env)
    @env = env
    emit("agent.turn.start", payload: { "iteration" => env[:current_iteration].to_i })
    begin
      @app.call(env)
      emit("agent.turn.end", payload: { "status" => "completed" })
    rescue StandardError => e
      emit("agent.turn.end", payload: { "status" => "error", "error" => e.message }, severity: "error")
      raise
    end
    env
  end

  def emit(kind, payload: {}, severity: "info")
    return unless @enabled

    event = {
      "kind" => kind,
      "time" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      "source" => { "component" => "agent", "name" => "main" },
      "severity" => severity,
      "payload" => payload,
    }
    @env[:events] << event if @env

    log_event(event) if loggable?(kind, severity)
    event
  end

  private

  def loggable?(kind, severity)
    return false if SEVERITIES.index(severity).to_i < SEVERITIES.index(@min_severity).to_i
    return false if @exclude.any? { |pattern| match?(pattern, kind) }

    @include.any? { |pattern| match?(pattern, kind) }
  end

  def match?(pattern, kind)
    pattern.end_with?("*") ? kind.start_with?(pattern[0...-1]) : pattern == kind
  end

  def log_event(event)
    line = "#{event["kind"]}"
    line += " #{event["payload"].inspect}" if @include_payload && !event["payload"].empty?
    (@logger || method(:warn)).call("[events] #{line}")
  end
end
