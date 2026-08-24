# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/messages"
require "brute/turn/pipeline"

module Brute
  module Turn

    #   agent = Brute.agent            # => AgentPipeline
    #     .use(Middleware::X)          # => same AgentPipeline (.use returns self)
    #     .run ->(env) { ... }         # => same AgentPipeline (.run returns self)
    #
    #   agent.start("what changed?")   # => runs the turn, returns env
    #
    class AgentPipeline < Pipeline

      # Register a slash command:
      #
      #   map("/compact") { |env| ... }
      #   map(/\Aplease compact/i) { |env| ... }
      #   map(->(said) { said.length > 10_000 }) { |env| ... }
      #
      # Whatever is given becomes a check: a function of what was said that
      # answers true or false. A String is a slash command -- "/compact"
      # becomes ^\/compact.*, the command and whatever rides after it -- and
      # a Regexp is wrapped in a function that evaluates it, so by the time
      # a command is registered there are only functions. Anything that
      # already answers to #call is taken as the check itself.
      #
      # This is Rack::Builder's `map` overridden: an agent routes on what was
      # said, not on a path, so there are no sub-builders and no URLMap.
      #
      # The block is a middleware. `start` puts the registry into the turn as
      # env[:commands], and SlashCommands -- which the builder puts at the
      # head of every chain -- runs the first command whose check passes on
      # the newest message, only when it is a user message, before the rest
      # of the stack.
      def map(matcher, &block)
        (@commands ||= []) << [check(matcher), block]
        self
      end

      # Every chain starts with the commands, registry or no registry: the
      # builder puts SlashCommands at its head rather than leaving it to a
      # `use` someone has to remember.
      def to_app
        Brute::Middleware::SlashCommands.new(super)
      end
      alias_method :build, :to_app

      def start(input = nil, events: NullSink.new)
        env = {
          messages:          coerce_messages(input),
          events:            events,
          metadata:          {},
          current_iteration: 1,
          commands:          @commands || [],
        }
        hooks.emit(TURN_START_EVENT, env)
        begin
          hooks.emit(TURN_DURATION_EVENT, env) { build.call(env) }
        ensure
          hooks.emit(TURN_END_EVENT, env)
        end
        env
      end

      private

        # A matcher becomes a function of what was said. A Regexp is
        # evaluated; a String is a slash command first -- given without its
        # slash, it grows one -- and then evaluated the same way.
        def check(matcher)
          if matcher.respond_to?(:call)
            matcher
          else
            pattern = pattern_for(matcher)
            ->(said) { pattern.match?(said) }
          end
        end

        def pattern_for(matcher)
          if matcher.is_a?(::Regexp)
            matcher
          else
            name = matcher.to_s
            name = name.start_with?("/") ? name : "/#{name}"
            /^#{::Regexp.escape(name)}.*/
          end
        end

        def coerce_messages(input)
          case input
          when nil                 then Brute.log
          when ::String            then Brute.log.tap { |log| log.user(input) }
          when ::Brute::Message    then Brute.log(input)
          when ::Hash              then Brute.log(Brute::Message.new(**input.transform_keys(&:to_sym)))
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

  it "Brute.load_agent loads an agent from a .ru file and starts it" do
    require "tmpdir"
    Dir.mktmpdir do |dir|
      path = File.join(dir, "agent.ru")
      File.write(path, 'run ->(env) { env[:messages].assistant("from file") }')

      agent = Brute.load_agent(path)
      agent.should.be.kind_of?(Brute::Turn::AgentPipeline)
      agent.start("hi")[:messages].last.content.should == "from file"
    end
  end

  it "Brute.load_agent raises for a missing file" do
    lambda { Brute.load_agent("definitely/not/here.ru") }.should.raise(ArgumentError)
  end

  it ".on chains off the builder and fires turn hooks around the turn" do
    fired = []
    agent = Brute.agent
      .run(->(env) { env[:messages].assistant("done") })
      .on(:turn_start) { |env| fired << [:start, env[:messages].last.content] }
      .on(:turn_end) { |env| fired << [:end, env[:messages].last.content] }

    env = agent.start("go")
    env[:messages].last.content.should == "done"
    fired.should == [[:start, "go"], [:end, "done"]]
  end

  it "fires turn_end on error (ensure)" do
    fired = []
    agent = Brute.agent
      .run(->(_env) { raise "boom" })
      .on(:turn_end) { |_env| fired << :end }

    lambda { agent.start("go") }.should.raise(RuntimeError)
    fired.should == [:end]
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

  it "runs a command's block as a middleware, before the rest of the stack" do
    order = []
    agent = Brute.agent
      .use(AgentStubMW)
      .map("/compact") { |env| order << [:compact, env[:messages].last.content] }
      .map("deploy") { |_env| order << :deploy }                 # grows its slash
      .map(/\Aplease compact\b/i) { |_env| order << :asked }     # a Regexp is evaluated
      .map(->(said) { said.length > 20 }) { |_env| order << :long }   # so is a function
      .run(->(env) { order << :app; env[:messages].assistant("done") })

    # The command runs first; the stack below it still runs.
    agent.start("/compact notes")
    order.should == [[:compact, "/compact notes"], :app]

    # A String matches the command and whatever rides after it.
    order.clear
    agent.start("/deploy now")
    order.should == [:deploy, :app]

    # Checks are tried in the order they were registered, and the first to
    # pass is the one that runs.
    order.clear
    agent.start("Please compact this, it has gone on long enough")
    order.should == [:asked, :app]

    order.clear
    agent.start("something else entirely, at some length")
    order.should == [:long, :app]

    # Conversation and unregistered commands reach the stack untouched.
    order.clear
    agent.start("just a question")
    agent.start("/unregistered")
    order.should == [:app, :app]

    # Only a user message says anything a command answers to.
    order.clear
    agent.start(Brute::Message.new(role: :assistant, content: "/compact"))
    order.should == [:app]

    # The registry rides in env, so anything below can see what was mapped.
    agent.start("hello")[:commands].size.should == 4
  end

  it "turns a matcher into a check that answers true or false" do
    checks = Brute.agent
      .map("/compact") { |_env| }
      .map("deploy") { |_env| }
      .map(/\Ahello/) { |_env| }
      .instance_variable_get(:@commands)
      .map(&:first)

    checks.each { |check| check.should.respond_to?(:call) }

    checks[0].call("/compact keep the notes").should.be.true
    checks[0].call("/compactor").should.be.true          # ^\/compact.* and no more
    checks[0].call("nope").should.be.false

    checks[1].call("/deploy now").should.be.true         # registered without the slash
    checks[1].call("deploy now").should.be.false

    checks[2].call("hello there").should.be.true
    checks[2].call("well hello").should.be.false
  end

  it "map chains, and every chain is built with the commands at its head" do
    agent = Brute.agent
      .map("/compact") { |_env| }
      .run(->(env) { env })

    agent.should.be.kind_of?(Brute::Turn::AgentPipeline)              # map returns self
    agent.build.should.be.kind_of?(Brute::Middleware::SlashCommands)  # and the head is the commands

    # No commands, same head.
    Brute.agent.run(->(env) { env }).build.should.be.kind_of?(Brute::Middleware::SlashCommands)
  end
end
