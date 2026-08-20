# frozen_string_literal: true

require "gem_kit"

require_relative "../completion/open_router"

module Brute
  module Middleware
    module OpenRouter
      # Deprecated. Completion middlewares now live under Brute::Completion,
      # which names them for what they do (call one provider) rather than for
      # where they happened to sit in the stack:
      #
      #   Brute::Middleware::OpenRouter::Completion  ->  Brute::Completion::OpenRouter
      #
      # The old name stays a working subclass of the new one until the deadline
      # below; see DEPRECATIONS.md and `gem kit deprecations`.
      class Completion < Brute::Completion::OpenRouter
        extend GemKit::Deprecate
        superseded_by "Brute::Completion::OpenRouter", "5.0"
      end
    end
  end
end

__END__

describe "brute/middleware/open_router" do
  require "brute/completion/open_router"

  it "is the new Completion class under the old name" do
    Brute::Middleware::OpenRouter::Completion.superclass.should == Brute::Completion::OpenRouter
  end

  it "warns on use, naming the replacement and the removal version" do
    captured = []
    original = GemKit::Deprecate.method(:warn)
    GemKit::Deprecate.define_singleton_method(:warn) { |message| captured << message }
    begin
      Brute::Middleware::OpenRouter::Completion.new(->(env) { env })
    ensure
      GemKit::Deprecate.define_singleton_method(:warn, original)
    end

    captured.size.should == 1
    captured.first.should.match(/Brute::Middleware::OpenRouter::Completion is deprecated/)
    captured.first.should.match(/use Brute::Completion::OpenRouter instead/)
    captured.first.should.match(/removed in 5\.0/)
  end

  it "is registered with its removal deadline" do
    entry = GemKit::Deprecate.registry.find { |e| e.name == "Brute::Middleware::OpenRouter::Completion" }
    entry.should.not.be.nil
    entry.removed_in.should == Gem::Version.new("5.0")
  end
end
