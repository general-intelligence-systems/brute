# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Tools
    class FSPatch < LLM::Tool
      name 'patch'
      description 'Replace a specific string in a file. The old_string must match exactly ' \
                  '(including whitespace and indentation). Always read a file before patching it.'

      param :file_path, String, 'Path to the file to patch', required: true
      param :old_string, String, 'The exact text to find and replace', required: true
      param :new_string, String, 'The replacement text', required: true
      param :replace_all, Boolean, 'Replace all occurrences (default: false)'

      def call(file_path:, old_string:, new_string:, replace_all: false)
        path = File.expand_path(file_path)
        Brute::FileMutationQueue.serialize(path) do
          raise "File not found: #{path}" unless File.exist?(path)

          original = File.read(path)
          raise "old_string not found in #{path}" unless original.include?(old_string)

          Brute::SnapshotStore.save(path)

          updated = if replace_all
                      original.gsub(old_string, new_string)
                    else
                      original.sub(old_string, new_string)
                    end

          File.write(path, updated)
          diff = Brute::Diff.unified(original, updated)
          count = replace_all ? original.scan(old_string).size : 1
          { success: true, file_path: path, replacements: count, diff: diff }
        end
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Tools::FSPatch do
    around(:each) { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:tool) { described_class.new }

    it "replaces old_string with new_string" do
      path = File.join(@dir, "test.rb")
      File.write(path, "hello world\n")
      result = tool.call(file_path: path, old_string: "world", new_string: "ruby")
      expect(result[:success]).to be true
      expect(File.read(path)).to eq("hello ruby\n")
    end

    it "returns a unified diff" do
      path = File.join(@dir, "test.rb")
      File.write(path, "line1\nold line\nline3\n")
      result = tool.call(file_path: path, old_string: "old line", new_string: "new line")
      expect(result[:diff]).to include("-old line")
      expect(result[:diff]).to include("+new line")
    end

    it "raises when file not found" do
      expect {
        tool.call(file_path: File.join(@dir, "nope.rb"), old_string: "a", new_string: "b")
      }.to raise_error(/File not found/)
    end

    it "raises when old_string not found" do
      path = File.join(@dir, "test.rb")
      File.write(path, "hello\n")
      expect {
        tool.call(file_path: path, old_string: "missing", new_string: "new")
      }.to raise_error(/old_string not found/)
    end

    it "supports replace_all" do
      path = File.join(@dir, "test.rb")
      File.write(path, "aaa bbb aaa\n")
      result = tool.call(file_path: path, old_string: "aaa", new_string: "ccc", replace_all: true)
      expect(result[:replacements]).to eq(2)
      expect(File.read(path)).to eq("ccc bbb ccc\n")
    end
  end
end
