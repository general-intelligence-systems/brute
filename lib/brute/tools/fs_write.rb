# frozen_string_literal: true

require "bundler/setup"
require "brute"
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
        Brute::Queue::FileMutationQueue.serialize(path) do
          old_content = File.exist?(path) ? File.read(path) : ''
          Brute::Store::SnapshotStore.save(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          diff = Brute::Diff.unified(old_content, content)
          { success: true, file_path: path, bytes: content.bytesize, diff: diff }
        end
      end
    end
  end
end

test do
  require "tmpdir"

  it "writes content to a new file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "new.rb")
      Brute::Tools::FSWrite.new.call(file_path: path, content: "hello\n")
      File.read(path).should == "hello\n"
    end
  end

  it "returns a diff for new files" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "new.rb")
      result = Brute::Tools::FSWrite.new.call(file_path: path, content: "line1\nline2\n")
      result[:diff].should =~ /\+line1/
    end
  end

  it "creates parent directories" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "deep", "nested", "file.rb")
      result = Brute::Tools::FSWrite.new.call(file_path: path, content: "nested\n")
      result[:success].should.be.true
    end
  end

  it "returns byte count" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.rb")
      result = Brute::Tools::FSWrite.new.call(file_path: path, content: "hello")
      result[:bytes].should == 5
    end
  end
end
