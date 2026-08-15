# frozen_string_literal: true

require "json"
require_relative "fs_sandbox"

# append_file — picoclaw `pkg/tools/fs/edit.go` (AppendFileTool).
# Read-modify-write (creates the file when absent), atomic rewrite, silent
# result upstream ("Silent" only suppresses the user-visible copy; the LLM
# content is what we return).
class AppendFile < Brute::Tool
  description "Append content to the end of a file. Standard JSON escaping applies: \\n for " \
              "newline and \\\\n for literal backslash-n."
  params({
    "type" => "object",
    "properties" => {
      "path" => { "type" => "string", "description" => "The file path to append to" },
      "content" => { "type" => "string", "description" => "The content to append. Standard JSON escaping applies: \\n for newline and \\\\n for literal backslash-n." },
    },
    "required" => %w[path content],
  })

  def initialize(workspace:, restrict: true, allow_paths: [])
    @fs = FsSandbox.build_fs(workspace, restrict, allow_paths)
  end

  def name = "append_file"

  def execute(**args)
    path = args[:path]
    return "path is required" unless path.is_a?(String)

    content = args[:content]
    return "content is required" unless content.is_a?(String)

    existing =
      begin
        @fs.read_file(path)
      rescue FsSandbox::Error => e
        raise unless e.kind == :not_found

        +"".b
      end

    @fs.write_file(path, existing + content.b)
    "Appended to #{path}"
  rescue FsSandbox::Error => e
    e.message
  rescue StandardError => e
    warn("append_file crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    e.message
  end
end
