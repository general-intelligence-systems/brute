# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Tools
    class FSUndo < LLM::Tool
      name "undo"
      description "Undo the last write or patch operation on a file, restoring it to " \
                  "its previous state."

      param :path, String, "Path to the file to undo", required: true

      def call(path:)
        target = File.expand_path(path)
        Brute::Queue::FileMutationQueue.serialize(target) do
          snapshot = Brute::Store::SnapshotStore.pop(target)
          raise "No undo history available for: #{target}" unless snapshot

          if snapshot == :did_not_exist
            File.delete(target) if File.exist?(target)
            {success: true, action: "deleted (file did not exist before)"}
          else
            File.write(target, snapshot)
            {success: true, action: "restored", bytes: snapshot.bytesize}
          end
        end
      end
    end
  end
end
