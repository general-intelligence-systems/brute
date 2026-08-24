# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # The head of every agent chain, put there by the builder itself rather
    # than by a `use` anyone writes. It switches on what was just said: the
    # newest message, and only when it is a user message, is offered to each
    # of env[:commands]'s checks in turn -- the commands registered with
    # `AgentPipeline#map`, which `start` puts there. The first check that
    # passes has its block run here, before the rest of the stack.
    #
    #   Brute.agent
    #     .map("/compact") { |env| ... }
    #     .run(->(env) { ... })
    #
    # A command's block is a middleware, so what it leaves in env is what
    # the rest of the chain works on.
    class SlashCommands < Brute::Middleware::Base
      def call(env)
        matched(env)&.call(env)
        @app.call(env)
      end

      private

        # The block of the first command whose check passes on what was just
        # said -- and nothing at all unless the room said it, so not the
        # assistant and not an empty log.
        def matched(env)
          message = Array(env[:messages]).last

          if message.respond_to?(:role) && message.role == :user
            _check, block = Array(env[:commands]).find { |check, _block| check.call(message.content.to_s) }
            block
          end
        end
    end
  end
end

__END__

describe "brute/middleware/001_slash_commands" do
  require "brute/messages"

  it "runs the first of env[:commands] whose check matches what was just said" do
    ran = []
    commands = [
      [->(said) { said.start_with?("/compact") }, ->(env) { ran << [:compact, env[:messages].last.content] }],
      [->(said) { said.length > 20 }, ->(_env) { ran << :long }],
    ]

    reached = []
    inner = ->(env) { reached << env[:messages].last&.content; env }
    middleware = Brute::Middleware::SlashCommands.new(inner)

    def turn(commands, said, role = :user)
      { commands: commands, messages: Brute.log.tap { |log| log << Brute::Message.new(role: role, content: said) } }
    end

    # The matching command runs before the stack below it.
    middleware.call(turn(commands, "/compact keep the notes"))
    ran.should == [[:compact, "/compact keep the notes"]]
    reached.should == ["/compact keep the notes"]

    # Checks are tried in order, and only the first to pass runs.
    ran.clear
    middleware.call(turn(commands, "something else, at some length"))
    ran.should == [:long]

    # Nothing matches, nothing runs -- and the turn carries on regardless.
    ran.clear
    reached.clear
    middleware.call(turn(commands, "short"))
    middleware.call(turn(commands, "/compact", :assistant))
    middleware.call({ commands: commands, messages: Brute.log })
    ran.should.be.empty
    reached.should == ["short", "/compact", nil]

    # A turn carrying no commands at all still runs, and does nothing.
    ran.clear
    middleware.call({ messages: Brute.log.tap { |log| log.user("/compact") } })
    ran.should.be.empty
  end
end
