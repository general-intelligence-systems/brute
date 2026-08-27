# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/hooks"

module Brute
  module Contrib
    # OpenTelemetry for a turn, as hooks rather than middleware.
    #
    #   Brute::Contrib::Otel.subscribe(agent)
    #   agent.start("what changed?")
    #
    # These are pure observers: they read the turn and write spans, and never
    # touch what the agent does. That is why they are subscribers and not
    # layers — a middleware earns its place in the stack by being able to
    # alter or skip what is below it, and telemetry never should.
    #
    # Every event it needs already exists:
    #
    #   turn_start / turn_end   the span itself
    #   llm_end               token usage, from env[:metadata][:last_llm_usage]
    #   tool_start / tool_end   a span event per tool call and result
    #
    # The tracer is injectable; without one it asks OpenTelemetry, and when
    # the SDK is not loaded `subscribe` does nothing at all.
    #
    # Note the span is opened and finished by hand rather than through
    # `tracer.in_span`, which wants a block around the work. OpenTelemetry's
    # current context is fiber-local, so this does not attach the span as
    # current: under Async a turn's LLM call and its tools may run in other
    # fibers, and an attached-but-never-detached context leaks across them.
    module Otel
      SPAN_NAME = "brute.turn"

      class << self
        def subscribe(agent, tracer: default_tracer)
          if tracer.nil?
            agent
          else
            agent
              .on(Brute::Hooks::TURN_START_EVENT) { |env| start(env, tracer) }
              .on(Brute::Hooks::TURN_END_EVENT) { |env| finish(env) }
              .on(Brute::Hooks::LLM_END_EVENT) { |env| record_usage(env) }
              .on(Brute::Hooks::TOOL_START_EVENT) { |env, call| tool_called(env, call) }
              .on(Brute::Hooks::TOOL_END_EVENT) { |env, call| tool_returned(env, call) }
              .on(Brute::Hooks::LLM_FAILURE_EVENT) { |env| failed(env) }
              .on(Brute::Hooks::MIDDLEWARE_DURATION_EVENT) { |env, started, finished, layer| layer_finished(
                env,
                started,
                finished,
                layer,
              ) }
              .on(Brute::Hooks::TURN_DURATION_EVENT) { |env, started, finished| timed(env, "turn", finished - started) }
              .on(Brute::Hooks::LLM_DURATION_EVENT) { |env, started, finished| timed(env, "llm", finished - started) }
              .on(Brute::Hooks::TOOL_DURATION_EVENT) { |env, started, finished, call| timed(
                env,
                "tool",
                finished - started,
                "tool.name" => call[:name].to_s,
              ) }
          end
        end

        def default_tracer
          if defined?(::OpenTelemetry)
            ::OpenTelemetry.tracer_provider.tracer("brute", Brute::VERSION)
          else
            nil
          end
        end

        private

          def start(env, tracer)
            env[:span] = tracer.start_span(
              SPAN_NAME,
              attributes: {
                "brute.messages" => env[:messages]&.size,
              }.compact,
            )
          end

          def finish(env)
            env[:span]&.finish
          end

          # The completions record a Brute::UsageDetection::Usage, so this
          # needs no per-provider knowledge: whatever the provider reported
          # arrives under the same names, and what it did not report is
          # absent rather than zero.
          def record_usage(env)
            span  = env[:span]
            usage = env.dig(:metadata, :last_llm_usage)

            if span && usage
              {
                "gen_ai.usage.input_tokens"      => usage.input,
                "gen_ai.usage.output_tokens"     => usage.output,
                "gen_ai.usage.total_tokens"      => usage.total,
                "gen_ai.usage.reasoning_tokens"  => usage.reasoning,
                "gen_ai.usage.cache_read_tokens" => usage.cache_read,
                "gen_ai.usage.cost"              => usage.cost,
              }.each do |name, value|
                unless value.nil?
                  span.set_attribute(name, value)
                end
              end
            end
          end

          def tool_called(env, call)
            env[:span]&.add_event(
              "tool_call",
              attributes: {
                "tool.name"      => call[:name].to_s,
                "tool.arguments" => call[:arguments].to_s,
              },
            )
          end

          def tool_returned(env, call)
            env[:span]&.add_event(
              "tool_result",
              attributes: {
                "tool.name"  => call[:name].to_s,
                "tool.bytes" => call[:result].to_s.bytesize,
              },
            )
          end

          # The layer's work is :middleware_duration's block, so start and finish arrive
          # with it rather than having to be correlated with :middleware_start by hand.
          def layer_finished(env, started, finished, layer)
            env[:span]&.add_event(
              "middleware",
              attributes: {
                "middleware.name"     => layer.class.name.to_s,
                "middleware.duration" => finished - started,
              },
            )
          end

          # Every pair in the turn has a timed middle, so each one's duration
          # lands as an attribute without correlating its edges.
          def timed(env, name, duration, attributes = {})
            env[:span]&.set_attribute("brute.#{name}.duration", duration)
            env[:span]&.add_event("#{name}_duration", attributes: attributes.merge("duration" => duration))
          end

          def failed(env)
            env[:span]&.add_event("llm_failure")
          end
      end
    end
  end
end

__END__

describe "brute/contrib/otel" do
  FakeSpan = Class.new do
    attr_reader :attributes, :events, :finished

    def initialize(name, attributes)
      @name = name
      @attributes = attributes.dup
      @events = []
      @finished = false
    end

    def set_attribute(name, value) = @attributes[name] = value
    def add_event(name, attributes: {}) = @events << [name, attributes]
    def finish = @finished = true
  end unless defined?(FakeSpan)

  FakeTracer = Class.new do
    attr_reader :spans

    def initialize = @spans = []

    def start_span(name, attributes: {})
      FakeSpan.new(name, attributes).tap { |span| @spans << span }
    end
  end unless defined?(FakeTracer)

  it "spans a turn, records normalised usage, and notes each tool call and result" do
    tracer = FakeTracer.new
    tool = { name: "echo", description: "", execute: ->(text:) { "ran:#{text}" } }

    agent = Brute::Turn::AgentPipeline.new
    agent.use Brute::Middleware::DefaultToolPipeline, tools: [tool]
    agent.run(Object.new.tap do |terminal|
      terminal.define_singleton_method(:call) do |env|
        # A completion records usage and announces the call; `run` bound this
        # emit to the pipeline's own store.
        env[:metadata][:last_llm_usage] = Brute::UsageDetection::Usage.new(input: 10, output: 5, total: 15)

        unless env[:called]
          env[:called] = true
          env[:messages] << Brute::Message.new(role: :assistant, content: "",
            tool_calls: [{ id: "tc1", name: "echo", arguments: { "text" => "hi" } }])
        end

        env.emit(Brute::Hooks::LLM_DURATION_EVENT) { :provider_call }
        env.emit(Brute::Hooks::LLM_END_EVENT)
        env
      end
    end)

    Brute::Contrib::Otel.subscribe(agent, tracer: tracer)
    agent.start("go")

    span = tracer.spans.first
    span.finished.should.be.true
    span.attributes["gen_ai.usage.total_tokens"].should == 15
    span.attributes["gen_ai.usage.input_tokens"].should == 10
    # Not reported by this provider, so never set.
    span.attributes.key?("gen_ai.usage.cost").should.be.false

    span.events.map(&:first).should.include "tool_call"
    span.events.map(&:first).should.include "tool_result"
    span.events.find { |name, _| name == "tool_call" }.last["tool.name"].should == "echo"

    # :middleware_end is timed, so each layer reports its own duration.
    layer_event = span.events.find { |name, _| name == "middleware" }
    layer_event.last["middleware.name"].should == "Brute::Middleware::DefaultToolPipeline"
    layer_event.last["middleware.duration"].should.be >= 0

    # Each pair's timed middle reports its own duration.
    span.attributes["brute.turn.duration"].should.be >= 0
    span.attributes["brute.llm.duration"].should.be >= 0
    span.attributes["brute.tool.duration"].should.be >= 0
    span.events.find { |name, _| name == "tool_duration" }.last["tool.name"].should == "echo"

    # Without a tracer — the SDK not loaded — subscribing is a no-op.
    quiet = Brute::Turn::AgentPipeline.new
    Brute::Contrib::Otel.subscribe(quiet, tracer: nil).should.be.identical_to quiet
  end
end
