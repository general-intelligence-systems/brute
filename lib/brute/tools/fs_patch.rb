# frozen_string_literal: true

module Brute
  module Tools
    class FSPatch < LLM::Tool
      name "patch"
      description "Replace a specific string in a file. The old_string must match exactly " \
                  "(including whitespace and indentation). Always read a file before patching it."

      param :file_path, String, "Path to the file to patch", required: true
      param :old_string, String, "The exact text to find and replace", required: true
      param :new_string, String, "The replacement text", required: true
      param :replace_all, Boolean, "Replace all occurrences (default: false)"

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
          {success: true, file_path: path, replacements: replace_all ? original.scan(old_string).size : 1}
        end
      end
    end
  end
end
