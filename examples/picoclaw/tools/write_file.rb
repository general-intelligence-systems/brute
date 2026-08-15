# frozen_string_literal: true

require "json"
require_relative "fs_sandbox"

# write_file — picoclaw `pkg/tools/fs/filesystem.go` (WriteFileTool).
# Refuses to overwrite an existing file unless overwrite=true; writes are
# atomic (temp + fsync + rename, 0600, parents created 0755).
#
# The description/overwrite copy names append_file/edit_file because both are
# registered here (upstream narrows WriteFileTool.altTools at registration,
# instance.go:112-124).
class WriteFile < Brute::Tool
  ALT_TOOLS_PHRASE = "append_file or edit_file"

  description "Write content to a file, replacing any existing content. Content is written " \
              "byte-for-byte after argument decoding. Standard JSON escaping applies: \\n for " \
              "newline and \\\\n for a literal backslash-n sequence. If the file already exists " \
              "you must set overwrite=true, which replaces the ENTIRE file. To add to or change " \
              "part of an existing file without losing its current contents, use " \
              "#{ALT_TOOLS_PHRASE} instead."
  params({
    "type" => "object",
    "properties" => {
      "path" => { "type" => "string", "description" => "Path to the file to write" },
      "content" => { "type" => "string", "description" => "Content to write to the file. Standard JSON escaping applies: \\n for newline and \\\\n for literal backslash-n." },
      "overwrite" => { "type" => "boolean", "description" => "Set to true to replace an existing file in full. This discards the file's current contents — to preserve them, use #{ALT_TOOLS_PHRASE} instead of write_file.", "default" => false },
    },
    "required" => %w[path content],
  })

  def initialize(workspace:, restrict: true, allow_paths: [])
    @fs = FsSandbox.build_fs(workspace, restrict, allow_paths)
  end

  def name = "write_file"

  def execute(**args)
    path = args[:path]
    return "path is required" unless path.is_a?(String)

    content = args[:content]
    return "content is required" unless content.is_a?(String)

    # Go: args["overwrite"].(bool) — only a JSON boolean true enables it.
    overwrite = args[:overwrite].is_a?(TrueClass)

    unless overwrite
      exists =
        begin
          @fs.open(path).close
          true
        rescue FsSandbox::Error
          false
        end
      if exists
        return "file: #{path} already exists. To add to it or change part of it without losing " \
               "the current contents, use #{ALT_TOOLS_PHRASE}. Only set overwrite=true if you " \
               "intend to replace the entire file."
      end
    end

    @fs.write_file(path, content.b)
    "File written: #{path}"
  rescue FsSandbox::Error => e
    e.message
  rescue StandardError => e
    warn("write_file crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    e.message
  end
end
