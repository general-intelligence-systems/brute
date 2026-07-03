# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/messages"
require "brute/turn/pipeline"

module Brute
  module Turn
    # An AgentPipeline is the runnable Agent *and* its own builder. It inherits
    # the whole Rack::Builder chain from Pipeline — so `.use`/`.run` chain
    # directly on it (each returns self) — and adds `#start(input)`, which
    # shapes the turn's env and runs the chain. There is no separate builder
    # object: the thing you configure is the thing you run.
    #
    #   agent = Brute.agent            # => AgentPipeline
    #     .use(Middleware::X)          # => same AgentPipeline (.use returns self)
    #     .run ->(env) { ... }         # => same AgentPipeline (.run returns self)
    #
    #   agent.start("what changed?")   # => runs the turn, returns env
    #
    # It carries NO configuration: LLM config lives in the terminal `run` proc,
    # tools go to the ToolPipeline middleware, the log to SessionLog.
    class AgentPipeline < Pipeline
      # Read and evaluate a brute.ru script string into a runnable Agent.
      # Inherited `parse_file` handles `.ru` files (with Rack's BOM / __END__
      # stripping) and funnels here; we override only to hand back the Agent
      # itself rather than Rack's built rack app.
      def self.new_from_string(script, path = "(brute)", **_opts)
        # rubocop:disable Security/Eval
        new.tap { |agent| eval(script, ::Rack::BUILDER_TOPLEVEL_BINDING.call(agent), path, 1) }
        # rubocop:enable Security/Eval
      end

      # Register a slash command. Slash-command routing rewrites a *prompt*
      # string before it reaches the turn, so it lives here on the agent turn —
      # not on the generic base Pipeline (a ToolPipeline has no prompt to route).
      #
      #   map "/weather", "Get the weather in the following location $ARGUMENTS"
      #   map("/weather") { "Get the weather in the following location $ARGUMENTS" }
      #
      def map(command, template = nil, &block)
        command = command.to_s
        command = command.start_with?("/") ? command : "/#{command}"

        (@map ||= {})[command] = block || proc { template }
        self
      end

      def generate_map(default_app, mapping)
        super.tap do |routes|
          routes.define_singleton_method(:call) do |prompt|
            name, args = prompt.to_s.strip.split(/\s+/, 2)
            prompt = mapping[name].call.to_s.gsub("$ARGUMENTS", args.to_s) if mapping[name]
            default_app.call(prompt)
          end
        end
      end

      # Start one turn. `input` seeds the conversation log (env[:messages]):
      #   - a String        -> a single user message
      #   - a RubyLLM::Message or an Array of them -> used as-is
      #   - nil             -> an empty log (e.g. when SessionLog loads history)
      # Returns the env hash so callers can read messages, metadata, etc.
      def start(input = nil, events: NullSink.new)
        env = {
          messages:          coerce_messages(input),
          events:            events,
          metadata:          {},
          current_iteration: 1,
        }
        build.call(env)
        env
      end

      private

        def coerce_messages(input)
          case input
          when nil                 then Brute.log
          when ::String            then Brute.log.tap { |log| log.user(input) }
          when ::RubyLLM::Message  then Brute.log(input)
          when ::Array             then input.extend(Brute::Messages)
          else Brute.log(input)
          end
        end
    end
  end
end

__END__

describe "brute/turn/agent_pipeline" do
  require "brute/messages"

  # A top-level stub middleware the eval'd scripts can reference.
  AgentStubMW = Class.new do
    def initialize(app); @app = app; end
    def call(env); env[:metadata][:mw] = true; @app.call(env); end
  end unless defined?(AgentStubMW)

  it "starts a turn and returns the env with the log in :messages" do
    agent = Brute.agent.run(->(env) { env[:messages].assistant("hello") })
    agent.should.be.kind_of?(Brute::Turn::AgentPipeline)

    env = agent.start("hi")
    env[:messages].map(&:role).should == [:user, :assistant]
    env[:messages].last.content.should == "hello"
  end

  it "coerces a String input into a user message" do
    captured = nil
    Brute.agent.run(->(env) { captured = env[:messages].dup }).start("a question")
    captured.first.role.should == :user
    captured.first.content.should == "a question"
  end

  it "shapes env with no config (that lives in the run proc)" do
    captured = nil
    Brute.agent.run(->(env) { captured = env }).start
    captured[:current_iteration].should == 1
    captured.key?(:provider).should.be.false
    captured.key?(:tools).should.be.false
  end

  it "is its own builder — .use and .run both return the AgentPipeline" do
    agent = Brute.agent.use(AgentStubMW)
    agent.should.be.kind_of?(Brute::Turn::AgentPipeline)

    agent.run { |env| env[:messages].assistant("done") }.should.equal?(agent)

    env = agent.start("go")
    env[:metadata][:mw].should.be.true
    env[:messages].last.content.should == "done"
  end

  it "parses a ru-style string into a runnable Agent" do
    agent = Brute::Turn::AgentPipeline.new_from_string('run ->(env) { env[:messages].assistant("from ru") }', "(test)")
    agent.should.be.kind_of?(Brute::Turn::AgentPipeline)
    agent.start("hi")[:messages].last.content.should == "from ru"
  end

  it "use in a ru string wraps the terminal" do
    script = <<~RUBY
      use AgentStubMW
      run ->(env) { env[:messages].assistant("ok") }
    RUBY
    Brute::Turn::AgentPipeline.new_from_string(script, "(test)").start("go")[:metadata][:mw].should.be.true
  end

  it "builds inline from a block passed to Brute.agent" do
    agent = Brute.agent do
      use AgentStubMW
      run ->(env) { env[:messages].assistant("done") }
    end
    agent.start("go")[:messages].last.content.should == "done"
  end

  it "map chains and to_app taps generate_map to build a (retargeted) URLMap" do
    agent = Brute.agent
      .map("/weather", "Get the weather in the following location $ARGUMENTS")
      .run(->(prompt) { prompt })

    agent.should.be.kind_of?(Brute::Turn::AgentPipeline)   # map returns self
    agent.build.should.be.kind_of?(::Rack::URLMap)         # to_app tapped generate_map (super)
  end

  it "swaps a /command prompt for its template ($ARGUMENTS) and calls the app" do
    got = nil
    agent = Brute.agent
      .map("/weather", "Get the weather in the following location $ARGUMENTS")
      .map("/echo") { "you said: $ARGUMENTS" }
      .run(->(prompt) { got = prompt })

    agent.call("/weather London")
    got.should == "Get the weather in the following location London"
    agent.call("/echo hi there")
    got.should == "you said: hi there"
  end

  it "passes non-commands through untouched (and normalizes the slash)" do
    got = nil
    agent = Brute.agent.map("weather", "W $ARGUMENTS").run(->(prompt) { got = prompt })

    agent.call("just a question")
    got.should == "just a question"
    agent.call("/weather NYC")   # registered as "weather", normalized to "/weather"
    got.should == "W NYC"
  end
end
