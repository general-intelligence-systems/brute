# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Eval
    # The world a case wakes up in.
    #
    # This one keeps nothing: what was said is handed straight to the turn,
    # and the tools answer from the case's stubs. It is what a plain agent
    # needs, and it is the contract a deployment's own world implements --
    # a world is anything that answers:
    #
    #   #prepare(case)      lay the world out for this case, and answer what
    #                       the turn should be started with (nil when the
    #                       world delivered what was said some other way, an
    #                       inbox on disk say)
    #   #stub(agent, stubs) install the case's canned tool results
    #   #published          whatever the turn sent outward, for the record
    #
    # Subclass to give a case somewhere to wake up:
    #
    #   class Room < Brute::Eval::World
    #     def prepare(kase)
    #       super.tap { |input| inbox.append(kase.said) if input.nil? }
    #     end
    #   end
    class World
      attr_reader :published

      def initialize
        @published = []
      end

      def prepare(kase)
        @published.clear
        kase.said
      end

      # :before_tool is handed a mutable call env, and a :result set on it is
      # answered without the tool ever running -- so a stub replaces the web,
      # the calendar or the shell without the agent being built differently.
      # A stub that answers to #call is handed the arguments.
      def stub(agent, stubs)
        agent.on(:before_tool) do |_env, call|
          canned = stubs[call[:name]]

          unless canned.nil?
            if canned.respond_to?(:call)
              call[:result] = canned.call(call[:arguments])
            else
              call[:result] = canned
            end
          end
        end
      end
    end
  end
end

__END__

describe "brute/eval/world" do
  it "hands what was said to the turn, and answers the tools from the case's stubs" do
    world = Brute::Eval::World.new
    kase = Brute::Eval::Case.new("asks", said: "what does it say?", stubs: { "search" => "canned" })

    world.prepare(kase).should == "what does it say?"
    world.published.should.be.empty

    search = Brute::Turn::ToolPipeline.new(name: "search", description: "search") do
      run ->(env) { env[:result] = "the live web" }
    end

    agent = Brute.agent
      .use(Brute::Middleware::DefaultToolPipeline, tools: [search])
      .run(
        ->(env) {
          env[:messages] << Brute::Message.new(
            role: :assistant,
            content: "",
            tool_calls: [{ id: "1", name: "search", arguments: {} }]
          )
        }
      )

    world.stub(agent, kase.stubs)
    agent.start("go")[:messages].last.content.should == "canned"

    unstubbed = Brute.agent
      .use(Brute::Middleware::DefaultToolPipeline, tools: [search])
      .run(
        ->(env) {
          env[:messages] << Brute::Message.new(
            role: :assistant,
            content: "",
            tool_calls: [{ id: "1", name: "search", arguments: {} }]
          )
        }
      )

    world.stub(unstubbed, {})
    unstubbed.start("go")[:messages].last.content.should == "the live web"
  end
end
