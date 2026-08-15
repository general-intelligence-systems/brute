# frozen_string_literal: true

require "json"
require "shellwords"

module HermesTools
  # search_files — content and file search backed by ripgrep. Port of
  # hermes-agent tools/file_tools.py search_files (local path).
  class SearchFiles < Brute::Tool
    description "Search file contents (ripgrep) or find files by name."
    params({
      "type" => "object",
      "properties" => {
        "pattern" => { "type" => "string", "description" => "The regex (content) or glob/substring (files) to search for" },
        "target" => { "type" => "string", "enum" => %w[content files], "default" => "content" },
        "path" => { "type" => "string", "description" => "Directory to search (default: current directory)", "default" => "." },
        "file_glob" => { "type" => "string", "description" => "Limit to files matching this glob (e.g. '*.rb')" },
        "limit" => { "type" => "integer", "description" => "Max results (default 50)", "default" => 50 },
        "offset" => { "type" => "integer", "description" => "Skip the first N results", "default" => 0 },
        "output_mode" => { "type" => "string", "enum" => %w[content files_only count], "default" => "content" },
        "context" => { "type" => "integer", "description" => "Lines of context around each match", "default" => 0 },
      },
      "required" => ["pattern"],
    })

    def name = "search_files"

    def execute(pattern:, target: "content", path: ".", file_glob: nil, limit: 50,
                offset: 0, output_mode: "content", context: 0, **_rest)
      return err("ripgrep (rg) is not installed or not on PATH") unless system("command -v rg >/dev/null 2>&1")

      limit = limit.to_i <= 0 ? 50 : limit.to_i

      if target == "files"
        cmd = ["rg", "--files", path]
        cmd += ["-g", file_glob] if file_glob
        out = `#{cmd.map(&:shellescape).join(" ")} 2>/dev/null`
        files = out.lines.map(&:chomp).select { |f| f.include?(pattern) }
        files = files.drop(offset.to_i).first(limit)
        return JSON.dump("files" => files, "count" => files.size)
      end

      cmd = ["rg", "--line-number", "--no-heading", "--color", "never"]
      cmd += ["--context", context.to_i] if context.to_i.positive?
      cmd += ["-g", file_glob] if file_glob
      case output_mode
      when "files_only" then cmd << "--files-with-matches"
      when "count" then cmd << "--count"
      end
      cmd += ["--", pattern, path]
      out = `#{cmd.map(&:shellescape).join(" ")} 2>/dev/null`
      lines = out.lines.map(&:chomp)
      lines = lines.drop(offset.to_i).first(limit)
      JSON.dump("matches" => lines, "count" => lines.size, "truncated" => out.lines.size > offset.to_i + limit)
    rescue StandardError => e
      err("#{e.class}: #{e.message}")
    end

    private

    def err(message)
      JSON.dump("error" => message)
    end
  end
end
