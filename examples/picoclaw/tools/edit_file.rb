# frozen_string_literal: true

require "json"
require_relative "fs_sandbox"
require_relative "diff_result"

# edit_file — picoclaw `pkg/tools/fs/edit.go` (EditFileTool).
# Byte-exact single-occurrence replacement: errors when old_text is absent or
# appears more than once; the whole file is read and rewritten atomically.
# Returns the LLM-facing DiffResult (summary + notes; the diff itself is
# user-surface only upstream).
class EditFile < Brute::Tool
  description "Edit a file by replacing old_text with new_text. The old_text must exist exactly " \
              "in the file. Standard JSON escaping applies: \\n for newline and \\\\n for " \
              "literal backslash-n."
  params({
    "type" => "object",
    "properties" => {
      "path" => { "type" => "string", "description" => "The file path to edit" },
      "old_text" => { "type" => "string", "description" => "The exact text to find and replace. Standard JSON escaping applies: \\n for newline and \\\\n for literal backslash-n." },
      "new_text" => { "type" => "string", "description" => "The text to replace with. Standard JSON escaping applies: \\n for newline and \\\\n for literal backslash-n." },
    },
    "required" => %w[path old_text new_text],
  })

  def initialize(workspace:, restrict: true, allow_paths: [])
    @fs = FsSandbox.build_fs(workspace, restrict, allow_paths)
  end

  def name = "edit_file"

  def execute(**args)
    path = args[:path]
    return "path is required" unless path.is_a?(String)

    old_text = args[:old_text]
    return "old_text is required" unless old_text.is_a?(String)

    new_text = args[:new_text]
    return "new_text is required" unless new_text.is_a?(String)

    before = @fs.read_file(path)
    needle = old_text.b
    return "old_text not found in file. Make sure it matches exactly" unless before.include?(needle)

    count = before.scan(needle).size
    return "old_text appears #{count} times. Please provide more context to make it unique" if count > 1

    after = before.sub(needle, new_text.b)
    @fs.write_file(path, after)
    DiffResult.llm_result(path, before, after)
  rescue FsSandbox::Error => e
    e.message
  rescue StandardError => e
    warn("edit_file crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    e.message
  end
end
