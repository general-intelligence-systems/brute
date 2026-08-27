# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/tools"

module Brute
  module Tools
    class FSPatch < Brute::Tool
      description 'Replace a specific string in a file. The old_string must match exactly ' \
                  '(including whitespace and indentation). Always read a file before patching it.'

      param :file_path, type: 'string', desc: 'Path to the file to patch', required: true
      param :old_string, type: 'string', desc: 'The exact text to find and replace', required: true
      param :new_string, type: 'string', desc: 'The replacement text', required: true
      param :replace_all, type: 'boolean', desc: 'Replace all occurrences (default: false)', required: false

      def name; "patch"; end

      def execute(file_path:, old_string:, new_string:, replace_all: false)
        path = File.expand_path(file_path)
        Brute::Tools::FS::FileMutationQueue.serialize(path) do
          unless File.exist?(path)
            raise "File not found: #{path}"
          end

          original = File.read(path)
          unless original.include?(old_string)
            raise "old_string not found in #{path}"
          end

          Brute::Tools::FS::SnapshotStore.save(path)

          if replace_all
            updated = original.gsub(old_string, new_string)
          else
            updated = original.sub(old_string, new_string)
          end

          File.write(path, updated)
          diff = Brute::Diff.unified(original, updated)
          if replace_all
            count = original.scan(old_string).size
          else
            count = 1
          end
          { success: true, file_path: path, replacements: count, diff: diff }
        end
      end
    end
  end
end

__END__

describe "brute/tools/fs_patch" do
  require "tmpdir"

  it "replaces old_string with new_string" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.rb")
      File.write(path, "hello world\n")
      result = Brute::Tools::FSPatch.new.call(file_path: path, old_string: "world", new_string: "ruby")
      File.read(path).should == "hello ruby\n"
    end
  end

  it "returns a unified diff" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.rb")
      File.write(path, "line1\nold line\nline3\n")
      result = Brute::Tools::FSPatch.new.call(file_path: path, old_string: "old line", new_string: "new line")
      result[:diff].should =~ /\-old line/
    end
  end

  it "raises when file not found" do
    Dir.mktmpdir do |dir|
      lambda {
        Brute::Tools::FSPatch.new.call(file_path: File.join(dir, "nope.rb"), old_string: "a", new_string: "b")
      }.should.raise(RuntimeError)
    end
  end

  it "raises when old_string not found" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.rb")
      File.write(path, "hello\n")
      lambda {
        Brute::Tools::FSPatch.new.call(file_path: path, old_string: "missing", new_string: "new")
      }.should.raise(RuntimeError)
    end
  end

  it "supports replace_all" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.rb")
      File.write(path, "aaa bbb aaa\n")
      result = Brute::Tools::FSPatch.new.call(file_path: path, old_string: "aaa", new_string: "ccc", replace_all: true)
      result[:replacements].should == 2
    end
  end
end
