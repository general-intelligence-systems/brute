# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

require 'fileutils'

module Brute
  module Tools
    class FSWrite < LLM::Tool
      name 'write'
      description "Write content to a file. Creates parent directories if they don't exist. " \
                  'Use this for creating new files or completely replacing file contents.'

      param :file_path, String, 'Path to the file to write', required: true
      param :content, String, 'The full content to write to the file', required: true

      def call(file_path:, content:)
        path = File.expand_path(file_path)
        Brute::FileMutationQueue.serialize(path) do
          old_content = File.exist?(path) ? File.read(path) : ''
          Brute::SnapshotStore.save(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          diff = Brute::Diff.unified(old_content, content)
          { success: true, file_path: path, bytes: content.bytesize, diff: diff }
        end
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Tools::FSWrite do
    around(:each) { |ex| Dir.mktmpdir { |d| @dir = d; ex.run } }

    let(:tool) { described_class.new }

    it "writes content to a new file" do
      path = File.join(@dir, "new.rb")
      result = tool.call(file_path: path, content: "hello\n")
      expect(result[:success]).to be true
      expect(File.read(path)).to eq("hello\n")
    end

    it "returns a diff for new files" do
      path = File.join(@dir, "new.rb")
      result = tool.call(file_path: path, content: "line1\nline2\n")
      expect(result[:diff]).to include("+line1")
      expect(result[:diff]).to include("+line2")
    end

    it "returns a diff for overwritten files" do
      path = File.join(@dir, "existing.rb")
      File.write(path, "old content\n")
      result = tool.call(file_path: path, content: "new content\n")
      expect(result[:diff]).to include("-old content")
      expect(result[:diff]).to include("+new content")
    end

    it "creates parent directories" do
      path = File.join(@dir, "deep", "nested", "file.rb")
      result = tool.call(file_path: path, content: "nested\n")
      expect(result[:success]).to be true
      expect(File.exist?(path)).to be true
    end

    it "returns byte count" do
      path = File.join(@dir, "test.rb")
      result = tool.call(file_path: path, content: "hello")
      expect(result[:bytes]).to eq(5)
    end
  end
end
