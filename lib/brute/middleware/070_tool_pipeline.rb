# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "gem_kit"

module Brute
  module Middleware
    # The old name for DefaultToolPipeline, kept working while it is
    # deprecated. The middleware is one particular wiring of tool dispatch and
    # the name now says so, leaving Brute::Turn::ToolPipeline as the mechanism
    # to compose when that wiring is not what you want.
    #
    #   use Brute::Middleware::DefaultToolPipeline, tools: tools
    #
    class ToolPipeline < DefaultToolPipeline
      extend GemKit::Deprecate
      superseded_by "Brute::Middleware::DefaultToolPipeline", "6.0"
    end
  end
end

__END__

describe "brute/middleware/070_tool_pipeline" do
  it "still dispatches tools under the old name, and says what to use instead" do
    warned = []
    original = GemKit::Deprecate.method(:warn)
    GemKit::Deprecate.define_singleton_method(:warn) { |message| warned << message }

    begin
      tool = Brute::Turn::ToolPipeline.new(name: "echo", description: "echo") do
        run ->(env) { env[:result] = "echoed" }
      end

      agent = Brute.agent
        .use(Brute::Middleware::ToolPipeline, tools: [tool])
        .run(
          ->(env) {
            env[:messages] << Brute::Message.new(
              role: :assistant,
              content: "",
              tool_calls: [{ id: "1", name: "echo", arguments: {} }]
            )
          }
        )

      agent.start("go")[:messages].last.content.should == "echoed"
    ensure
      GemKit::Deprecate.define_singleton_method(:warn, original)
    end

    Brute::Middleware::ToolPipeline.ancestors.should.include Brute::Middleware::DefaultToolPipeline
    warned.first.should.include "Brute::Middleware::DefaultToolPipeline"
    warned.first.should.include "6.0"

    declared = GemKit::Deprecate.registry.find { |entry| entry.name == "Brute::Middleware::ToolPipeline" }
    declared.replacement.should == "Brute::Middleware::DefaultToolPipeline"
    declared.removed_in.should == Gem::Version.new("6.0")
  end
end
