# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../path_guards"

module HermesTools
  # write_file — full-file writes. Port of hermes-agent tools/file_tools.py
  # write_file_tool (local path): parent dirs created, sensitive paths refused,
  # and read_file's line-numbered display text refused as content.
  class WriteFile < Brute::Tool
    description "Write content to a file, creating parent directories as needed."
    params({
      "type" => "object",
      "properties" => {
        "path" => { "type" => "string", "description" => "Path to the file to write" },
        "content" => { "type" => "string", "description" => "The full content to write" },
      },
      "required" => %w[path content],
    })

    def name = "write_file"

    def execute(path:, content:, **_rest)
      guard = Hermes::PathGuards.check(path)
      return err(guard) if guard

      if Hermes::PathGuards.internal_display_text?(content)
        return err("Refusing to write internal read_file display text as file content. " \
                   "Strip read_file line-number prefixes or reconstruct the intended file contents before writing.")
      end

      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, content, encoding: Encoding::UTF_8)
      File.rename(tmp, path)
      JSON.dump("success" => true, "path" => path, "bytes" => content.bytesize)
    rescue SystemCallError, IOError => e
      err("#{e.class}: #{e.message}")
    end

    private

    def err(message)
      JSON.dump("error" => message)
    end
  end
end
