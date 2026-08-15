# frozen_string_literal: true

require "json"
require_relative "../path_guards"

module HermesTools
  # read_file — paginated file reads with line numbers. Port of hermes-agent
  # tools/file_tools.py read_file_tool (local path).
  #
  #   * offset/limit pagination (offset ≥ 1, limit ≤ 2000)
  #   * compact "N|content" line numbers (token-cheaper gutter)
  #   * guards: device/special files refused (FIFO/socket/device would block);
  #     binary extensions refused; NUL-byte sniffing for extension-less files;
  #     credential paths refused
  #   * char budget: trim to the last complete line that fits + next_offset hint
  #   * not-found: similar-file suggestions from the parent dir
  #   * per-instance dedup: an unchanged re-read of the same (path, offset,
  #     limit) returns a stub; a third repeat is hard-blocked (anti-loop)
  class ReadFile < Brute::Tool
    description "Read a file with pagination and line numbers (N|content). " \
                "Use offset/limit to page through large files."
    params({
      "type" => "object",
      "properties" => {
        "path" => { "type" => "string", "description" => "Path to the file to read" },
        "offset" => { "type" => "integer", "description" => "1-based line to start at (default 1)", "minimum" => 1 },
        "limit" => { "type" => "integer", "description" => "Max lines to return (default 2000, max 2000)", "maximum" => 2000 },
      },
      "required" => ["path"],
    })

    MAX_READ_CHARS = 100_000
    BINARY_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .pdf .zip .gz .tar .bin .exe .so .o .a .woff .woff2 .ttf .mp3 .mp4 .mov .sqlite .db].freeze
    DEDUP_STUB_MESSAGE = "File unchanged since your last read of this region — the content above is still current."

    def initialize
      @reads = {} # [path, offset, limit] => mtime
      @stub_hits = Hash.new(0)
    end

    def name = "read_file"

    def execute(path:, offset: 1, limit: 2000, **_rest)
      offset = [[offset.to_i, 1].max, 1].max
      limit = limit.to_i
      limit = 2000 if limit <= 0 || limit > 2000

      guard = Hermes::PathGuards.check(path)
      return err(guard) if guard

      return err("Cannot read '#{path}': this is a device file that would block or produce infinite output.") if device_path?(path)
      return err("File not found: #{path}#{similar_hint(path)}") unless File.exist?(path)
      if (kind = special_kind(path))
        return JSON.dump("success" => false,
                         "note" => "'#{path}' is #{kind}, not a regular file — reading it would block indefinitely. Use terminal utilities if you need to interact with it.")
      end
      ext = File.extname(path).downcase
      if BINARY_EXTENSIONS.include?(ext)
        return err("Cannot read binary file '#{path}' (#{ext}). Use vision_analyze for images, or terminal to inspect binary files.")
      end

      key = [File.expand_path(path), offset, limit]
      if @reads[key] && @reads[key] == File.mtime(path)
        @stub_hits[key] += 1
        if @stub_hits[key] >= 2
          return err("BLOCKED: You have called read_file on this exact region repeatedly and the file has NOT changed. " \
                     "STOP calling read_file for this path — the earlier result is still current.")
        end
        return JSON.dump("status" => "unchanged", "message" => DEDUP_STUB_MESSAGE, "path" => path, "dedup" => true, "content_returned" => false)
      end

      raw = File.read(path, encoding: Encoding::UTF_8)
      return err("Cannot read '#{path}': file contains NUL bytes (binary). Use terminal to inspect.") if raw.include?("\x00")

      lines = raw.lines
      total = lines.size
      end_line = offset + limit - 1
      page = lines[(offset - 1)..(end_line - 1)] || []
      content = add_line_numbers(page.join, offset)

      result = {
        "content" => content,
        "total_lines" => total,
        "file_size" => raw.bytesize,
        "truncated" => total > end_line,
      }
      result["hint"] = "Use offset=#{end_line + 1} to continue reading (showing #{offset}-#{[end_line, total].min} of #{total} lines)" if result["truncated"]

      if content.length > MAX_READ_CHARS
        trimmed, kept = trim_to_budget(content, MAX_READ_CHARS)
        next_offset = offset + kept
        result["content"] = trimmed
        result["truncated"] = true
        result["truncated_by"] = "bytes"
        result["next_offset"] = next_offset
        result["hint"] = "Output truncated at the #{MAX_READ_CHARS}-char read budget after #{kept} line(s). Use offset=#{next_offset} to continue."
      end

      @reads[key] = File.mtime(path)
      JSON.dump(result)
    rescue SystemCallError, IOError => e
      err("#{e.class}: #{e.message}")
    end

    private

    def err(message)
      JSON.dump("error" => message)
    end

    def add_line_numbers(content, start_line)
      content.lines.each_with_index.map { |line, i| "#{start_line + i}|#{line}" }.join
    end

    def trim_to_budget(content, budget)
      kept = []
      total = 0
      content.each_line do |line|
        break if total + line.length > budget

        kept << line
        total += line.length
      end
      return [content[0, budget], 1] if kept.empty? # first line alone exceeds — clamp mid-line

      [kept.join, kept.size]
    end

    def device_path?(path)
      path.start_with?("/dev/", "/proc/")
    end

    def special_kind(path)
      stat = File.stat(path)
      return "a FIFO/socket" if stat.pipe? || stat.socket?
      return "a device" if stat.chardev? || stat.blockdev?

      nil
    rescue SystemCallError
      nil
    end

    def similar_hint(path)
      dir = File.dirname(path)
      base = File.basename(path).downcase
      return "" unless Dir.exist?(dir)

      similar = Dir.children(dir).select { |f| f.downcase.include?(base[0, [base.size, 4].min]) }.first(5)
      similar.empty? ? "" : " Did you mean: #{similar.join(', ')}?"
    end
  end
end
