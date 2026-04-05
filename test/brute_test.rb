# frozen_string_literal: true

require "test_helper"

class BruteTest < Minitest::Test
  def test_version
    refute_nil Brute::VERSION
  end
end
