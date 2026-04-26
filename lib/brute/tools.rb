# frozen_string_literal: true

require "brute"

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
      Tools::Delegate,
      Tools::Question
    ].freeze
  end
end
