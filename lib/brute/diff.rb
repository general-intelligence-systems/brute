# frozen_string_literal: true

require 'diff/lcs'
require 'diff/lcs/hunk'

module Brute
  module Diff
    # Generate a unified diff string from two texts.
    def self.unified(old_text, new_text, context: 3)
      old_lines = old_text.lines
      new_lines = new_text.lines
      diffs = ::Diff::LCS.diff(old_lines, new_lines)
      return '' if diffs.empty?

      output = +''
      file_length_difference = 0
      diffs.each do |piece|
        hunk = ::Diff::LCS::Hunk.new(old_lines, new_lines, piece, context, file_length_difference)
        file_length_difference = hunk.file_length_difference
        output << hunk.diff(:unified)
        output << "\n"
      end
      output
    end
  end
end
