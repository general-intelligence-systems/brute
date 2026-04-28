# frozen_string_literal: true

require "bundler/setup"
require "brute"

Dir.glob("#{__dir__}/tools/**/*.rb").sort.each do |path|
  require path
end

module Brute
  module Tools
    ALL = [
      Tools::FSRead,
      Tools::FSWrite,
      Tools::FSPatch,
      Tools::FSRemove,
      Tools::FSSearch,
      Tools::FSUndo,
      Tools::Shell,
      Tools::NetFetch,
      Tools::TodoWrite,
      Tools::TodoRead,
      Tools::Question
    ].freeze
  end
end
