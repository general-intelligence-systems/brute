# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

require "fileutils"

module Brute
  module Tools
    class FSRemove < RubyLLM::Tool
      description "Remove a file or empty directory."

      param :path, type: 'string', desc: "Path to the file or directory to remove", required: true

      def name; "remove"; end

      def execute(path:)
        target = File.expand_path(path)
        Brute::Queue::FileMutationQueue.serialize(target) do
          raise "Path not found: #{target}" unless File.exist?(target)

          Brute::Store::SnapshotStore.save(target) if File.file?(target)

          if File.directory?(target)
            Dir.rmdir(target)
          else
            File.delete(target)
          end

          {success: true, path: target}
        end
      end
    end
  end
end
