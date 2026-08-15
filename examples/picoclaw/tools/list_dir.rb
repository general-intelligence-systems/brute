# frozen_string_literal: true

require "json"
require_relative "fs_sandbox"

# list_dir — picoclaw `pkg/tools/fs/filesystem.go` (ListDirTool).
# Flat `DIR:  <name>` / `FILE: <name>` lines (two/one space), sorted by name,
# symlinks reported by lstat semantics (a symlink to a directory is a FILE).
# A missing/invalid path arg falls back to "." (upstream quirk: path is
# declared required but a failed type assertion defaults to the workspace).
class ListDir < Brute::Tool
  description "List files and directories in a path"
  params({
    "type" => "object",
    "properties" => {
      "path" => { "type" => "string", "description" => "Path to list" },
    },
    "required" => ["path"],
  })

  def initialize(workspace:, restrict: true, allow_paths: [])
    @fs = FsSandbox.build_fs(workspace, restrict, allow_paths)
  end

  def name = "list_dir"

  def execute(**args)
    path = args[:path]
    path = "." unless path.is_a?(String)

    abs, names = @fs.read_dir(path)
    out = +""
    names.each do |entry|
      is_dir =
        begin
          File.lstat(File.join(abs, entry)).directory?
        rescue SystemCallError
          false
        end
      out << (is_dir ? "DIR:  #{entry}\n" : "FILE: #{entry}\n")
    end
    out
  rescue FsSandbox::Error => e
    "failed to read directory: #{e.message}"
  rescue SystemCallError => e
    "failed to read directory: #{e.message}"
  rescue StandardError => e
    warn("list_dir crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    e.message
  end
end
