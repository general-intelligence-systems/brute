# frozen_string_literal: true

require "bundler/setup"
require "brute"
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

test do
  it "generates a unified diff for changed content" do
    Brute::Diff.unified("line1\nold\nline3\n", "line1\nnew\nline3\n").should =~ /\-old/
  end

  it "includes additions in diff" do
    Brute::Diff.unified("line1\nold\nline3\n", "line1\nnew\nline3\n").should =~ /\+new/
  end

  it "returns empty string for identical content" do
    Brute::Diff.unified("same\ncontent\n", "same\ncontent\n").should == ""
  end

  it "handles empty old content (new file)" do
    Brute::Diff.unified("", "new\ncontent\n").should =~ /\+new/
  end

  it "handles empty new content (deleted file)" do
    Brute::Diff.unified("old\ncontent\n", "").should =~ /\-old/
  end
end
