# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/hooks"

module Brute
  module Middleware
    # The parent of every middleware: it takes the next app, does its work
    # around it, and calls it.
    #
    #   class Shout < Brute::Middleware::Base
    #     def call(env)
    #       emit(ENTER_EVENT, env, self)
    #       @app.call(env)
    #     end
    #   end
    #
    # Brute::Hooks is included, so the event names are first class in every
    # subclass — ENTER_EVENT, not Brute::Hooks::ENTER_EVENT.
    class Base
      include Brute::Hooks

      def initialize(app, *, **)
        @app = app
      end

      # A layer that adds nothing passes the turn straight through.
      def call(env) = @app.call(env)

      private

        attr_reader :app
    end
  end
end

__END__

describe "brute/middleware/000_base" do
  it "carries the app, passes the turn through, and makes the event names first class" do
    passed = []
    terminal = ->(env) { passed << env; env }

    Brute::Middleware::Base.new(terminal).call({ turn: 1 }).should == { turn: 1 }
    passed.should == [{ turn: 1 }]

    # Whatever a subclass declares, the base swallows.
    Brute::Middleware::Base.new(terminal, :extra, keyword: true).call({}).should == {}

    # The event names resolve through the class itself, so a subclass writes
    # ENTER_EVENT rather than Brute::Hooks::ENTER_EVENT.
    Brute::Middleware::Base.const_get(:ENTER_EVENT).should == :enter
    Brute::Middleware::SystemPrompt.const_get(:AFTER_TOOL_EVENT).should == :after_tool

    # Every middleware in the chain descends from it.
    Brute::Middleware::SystemPrompt.ancestors.should.include Brute::Middleware::Base
    Brute::Middleware::DefaultToolPipeline.ancestors.should.include Brute::Middleware::Base
    Brute::Middleware::Loop::ToolResult.ancestors.should.include Brute::Middleware::Base
  end
end
