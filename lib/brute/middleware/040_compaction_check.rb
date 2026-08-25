# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "gem_kit"

module Brute
  module Middleware
    # The old compaction trigger, kept working while it is deprecated.
    # DefaultCompactionPipeline is the layer that does the job.
    #
    # It passes the turn through and compacts nothing, which is what it always
    # did -- and it is deliberately not a subclass of its replacement, because
    # inheriting would make a layer that did nothing suddenly start giving up
    # context. A deprecation warns about a name; it does not change what the
    # code under that name does.
    #
    # Whatever it was configured with is accepted and ignored, so existing
    # `use` lines keep parsing until they are moved over:
    #
    #   use Brute::Middleware::DefaultCompactionPipeline,
    #     window:     200_000,
    #     summariser: Brute::Completion::OpenRouter.new(config: { access_token: key })
    #
    class CompactionCheck < Brute::Middleware::Base
      extend GemKit::Deprecate
      superseded_by "Brute::Middleware::DefaultCompactionPipeline", "6.0"

      def initialize(app, **_options)
        @app = app
      end

      def call(env) = @app.call(env)
    end
  end
end

__END__

describe "brute/middleware/040_compaction_check" do
  it "passes the turn through as it always did, and says what to use instead" do
    warned = []
    original = GemKit::Deprecate.method(:warn)
    GemKit::Deprecate.define_singleton_method(:warn) { |message| warned << message }

    begin
      # Whatever it was configured with is taken and ignored, so an existing
      # `use` line keeps parsing.
      layer = Brute::Middleware::CompactionCheck.new(
        ->(env) { env[:messages].assistant("answered") },
        system_prompt: "you are helpful",
        token_threshold: 100
      )

      env = { messages: Brute.log }
      layer.call(env)
      env[:messages].last.content.should == "answered"
    ensure
      GemKit::Deprecate.define_singleton_method(:warn, original)
    end

    # Not a subclass of its replacement: a layer that compacted nothing must
    # not start compacting because its name was deprecated.
    Brute::Middleware::CompactionCheck.ancestors
      .should.not.include Brute::Middleware::DefaultCompactionPipeline

    warned.first.should.include "Brute::Middleware::DefaultCompactionPipeline"

    declared = GemKit::Deprecate.registry.find { |entry| entry.name == "Brute::Middleware::CompactionCheck" }
    declared.replacement.should == "Brute::Middleware::DefaultCompactionPipeline"
    declared.removed_in.should == Gem::Version.new("6.0")
  end
end
