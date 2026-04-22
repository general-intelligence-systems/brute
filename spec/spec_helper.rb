# frozen_string_literal: true

require "bundler/setup"
require "rspec/autorun"
require "brute"
require "tmpdir"
require "logger"
require "stringio"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.before(:each) do
    Brute::Store::SnapshotStore.clear!
    Brute::Store::TodoStore.clear!
  end
end
