# frozen_string_literal: true

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
