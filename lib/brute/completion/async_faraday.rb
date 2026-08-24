# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Completion
    # Faraday's own default adapter is Net::HTTP, which works under Async but
    # opens a fresh connection for every request. Provider gems build their
    # own Faraday connections and give no seam to configure them, so the
    # adapter is swapped at the only place it can be: Faraday's default.
    #
    # Called by each completion whose provider gem rides on Faraday, after
    # that gem is required — so it only fires when Faraday is genuinely in
    # play, and an app that uses a completion which doesn't (llm.rb speaks
    # Net::HTTP directly) never loads any of it.
    def self.async_faraday!
      return false unless defined?(::Faraday)

      require "async/http/faraday/default"
      true
    end
  end
end

__END__

describe "brute/completion/async_faraday" do
  it "points Faraday's default adapter at async-http, and does nothing without Faraday" do
    require "faraday"
    Brute::Completion.async_faraday!.should.be.true
    ::Faraday.default_adapter.should == :async_http

    # Idempotent: a second completion constructing does not undo the first.
    Brute::Completion.async_faraday!.should.be.true
    ::Faraday.default_adapter.should == :async_http
  end
end
