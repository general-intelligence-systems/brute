# frozen_string_literal: true

require 'brute'
require 'tmpdir'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.before(:each) do
    Brute::SnapshotStore.clear!
    Brute::TodoStore.clear!
  end
end
