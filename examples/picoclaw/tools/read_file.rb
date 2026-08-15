# frozen_string_literal: true

require "json"
require_relative "fs_sandbox"

# read_file — picoclaw `pkg/tools/fs/filesystem.go` (ReadFileTool bytes mode,
# ReadFileLinesTool lines mode; one tool name, picked by tools.read_file.mode).
#
# Bytes mode paginates with offset/length (length silently capped at
# max_read_file_size, default 64KB) and answers with a basename-only metadata
# header plus TRUNCATED/END-OF-FILE markers. Lines mode emits
# `LINE_NUMBER|LINE_CONTENT` under the same byte budget, rejects binary files
# and offset-style args, and uses PARTIAL/TRUNCATED resume hints.
#
# Go's JSON transport replaces invalid UTF-8 with U+FFFD at marshal time; we
# scrub at return instead — the wire content is identical.
class ReadFile < Brute::Tool
  MAX_READ_FILE_SIZE = 64 * 1024

  BYTES_DESCRIPTION = "Read the contents of a file. Supports pagination via `offset` and `length`."
  LINES_DESCRIPTION = "Read a UTF-8 text file from the filesystem. Output always includes line numbers in the format `LINE_NUMBER|LINE_CONTENT` (1-indexed). Supports partial reads via `start_line` and `max_lines` for large text files."

  BYTES_SCHEMA = {
    "type" => "object",
    "properties" => {
      "path" => { "type" => "string", "description" => "Path to the file to read." },
      "offset" => { "type" => "integer", "description" => "Byte offset to start reading from.", "default" => 0 },
      "length" => { "type" => "integer", "description" => "Maximum number of bytes to read.", "default" => MAX_READ_FILE_SIZE },
    },
    "required" => ["path"],
  }.freeze
  LINES_SCHEMA = {
    "type" => "object",
    "properties" => {
      "path" => { "type" => "string", "description" => "Path to the file to read." },
      "start_line" => { "type" => "integer", "description" => "Line number to start reading from (1-indexed, inclusive).", "default" => 1 },
      "max_lines" => { "type" => "integer", "description" => "Maximum number of lines to read." },
    },
    "required" => ["path"],
  }.freeze

  description BYTES_DESCRIPTION
  params BYTES_SCHEMA

  def initialize(workspace:, restrict: true, mode: "bytes", max_size: nil, allow_paths: [])
    @mode = mode.to_s
    @max_size = max_size.to_i.positive? ? max_size.to_i : MAX_READ_FILE_SIZE
    @fs = FsSandbox.build_fs(workspace, restrict, allow_paths)
  end

  def name = "read_file"
  def description = @mode == "lines" ? LINES_DESCRIPTION : BYTES_DESCRIPTION
  def params_schema = @mode == "lines" ? LINES_SCHEMA : BYTES_SCHEMA

  def execute(**args)
    @mode == "lines" ? execute_lines(args) : execute_bytes(args)
  rescue FsSandbox::Error => e
    e.message
  rescue StandardError => e
    warn("read_file crashed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    e.message
  end

  private

  # --- bytes mode -------------------------------------------------------------

  def execute_bytes(args)
    path = args[:path]
    return "path is required" unless path.is_a?(String)

    offset, err = int64_arg(args, :offset, 0)
    return err if err
    return "offset must be >= 0" if offset.negative?

    length, err = int64_arg(args, :length, @max_size)
    return err if err
    return "length must be > 0" if length <= 0

    length = @max_size if length > @max_size

    file = @fs.open(path)
    begin
      total_size =
        begin
          file.stat.size
        rescue SystemCallError
          -1
        end

      # Sniff then rewind (regular files are always seekable; upstream's
      # non-seekable branches are unreachable here).
      begin
        file.read(512)
      rescue SystemCallError
        nil # sniff errors ignored upstream
      end
      begin
        file.rewind
        file.seek(offset, IO::SEEK_SET)
        probe = file.read(length + 1) # read length+1 to detect "more" without trusting stat
      rescue SystemCallError => e
        return "failed to read file content: #{e.message}"
      end

      n = probe&.bytesize || 0
      has_more = n > length
      data = n.zero? ? +"".b : probe.byteslice(0, [n, length].min)

      return "[END OF FILE - no content at this offset]" if data.empty?

      read_end = offset + data.bytesize
      range = "bytes #{offset}-#{read_end - 1}"
      header =
        if total_size >= 0
          "[file: #{File.basename(path)} | total: #{total_size} bytes | read: #{range}]"
        else
          "[file: #{File.basename(path)} | read: #{range} | total size unknown]"
        end
      header +=
        if has_more
          "\n[TRUNCATED - file has more content. Call read_file again with offset=#{read_end} to continue.]"
        else
          "\n[END OF FILE - no further content.]"
        end

      (header + "\n\n" + data).force_encoding(Encoding::UTF_8).scrub
    ensure
      file.close
    end
  end

  # --- lines mode -------------------------------------------------------------

  def execute_lines(args)
    path = args[:path]
    return "path is required" unless path.is_a?(String)

    start_line, err = int64_arg(args, :start_line, 1)
    return err if err
    return "start_line must be >= 1" if start_line < 1
    return "offset is not supported in line mode; use start_line" if args.key?(:offset)
    return "length is not supported in line mode; use max_lines" if args.key?(:length)
    return "limit is not supported in line mode; use max_lines" if args.key?(:limit)

    limit = -1
    if args.key?(:max_lines) && !args[:max_lines].nil?
      limit, err = int64_arg(args, :max_lines, -1)
      return err if err
      return "max_lines, if provided, must be > 0" if limit <= 0
    end

    file = @fs.open(path)
    begin
      begin
        return "failed to open file: path is a directory: #{path}" if file.stat.directory?
      rescue SystemCallError
        nil # stat failure ignored, reads below will surface real errors
      end

      begin
        sample = file.read(512).to_s
      rescue SystemCallError => e
        return "failed to read file: #{e.message}"
      end
      if FsSandbox.binary_data?(sample)
        return "file appears to be binary; switch read_file mode to 'bytes' for byte-based inspection"
      end
      file.rewind

      content = +"".b
      line_index = 1
      lines_read = 0
      file_bytes_read = 0
      output_bytes_read = 0
      reached_eof = false
      byte_budget_truncated = false
      line_truncated = false

      while line_index < start_line
        line =
          begin
            file.gets
          rescue SystemCallError => e
            return "failed to read file content: #{e.message}"
          end
        if line.nil?
          reached_eof = true
          break
        end
        line_index += 1
      end

      while !reached_eof && (limit.negative? || lines_read < limit)
        prefix = "#{line_index}|"
        remaining = @max_size - output_bytes_read - prefix.bytesize
        if remaining <= 0
          byte_budget_truncated = true
          break
        end

        line =
          begin
            file.gets
          rescue SystemCallError => e
            return "failed to read file content: #{e.message}"
          end
        if line.nil?
          reached_eof = true
          break
        end

        complete = true
        if line.bytesize > remaining
          line = line.byteslice(0, remaining)
          complete = false
        end

        content << prefix << line
        file_bytes_read += line.bytesize
        output_bytes_read += prefix.bytesize + line.bytesize
        lines_read += 1
        line_index += 1

        unless complete
          byte_budget_truncated = true
          line_truncated = true
          break
        end
      end

      if !reached_eof && !line_truncated
        has_more =
          begin
            !file.read(1).nil?
          rescue SystemCallError => e
            return "failed to inspect remaining file content: #{e.message}"
          end
        unless has_more
          reached_eof = true
          byte_budget_truncated = false
        end
      end

      return "[END OF FILE - no content at or after start_line=#{start_line}]" if lines_read.zero? && content.empty?

      end_line = start_line + lines_read - 1
      header = "[file: #{File.basename(path)} | read: lines #{start_line}-#{end_line} (1-indexed) | file_bytes: #{file_bytes_read} | output_bytes: #{output_bytes_read}]"
      header +=
        if line_truncated
          "\n[TRUNCATED - line #{end_line} exceeded the #{@max_size} byte read budget and was cut mid-line.]"
        elsif byte_budget_truncated
          if limit.positive?
            "\n[TRUNCATED - byte budget reached. Call read_file again with start_line=#{start_line + lines_read} and max_lines=#{limit} to continue at the next line.]"
          else
            "\n[TRUNCATED - byte budget reached. Call read_file again with start_line=#{start_line + lines_read} to continue at the next line.]"
          end
        elsif !reached_eof && limit.positive? && lines_read >= limit
          "\n[PARTIAL - more content remains. Call read_file again with start_line=#{start_line + lines_read} and max_lines=#{limit} to continue.]"
        else
          "\n[END OF FILE - no further content.]"
        end

      (header + "\n\n" + content).force_encoding(Encoding::UTF_8).scrub
    ensure
      file.close
    end
  end

  # getInt64Arg port: integral floats, integers, and decimal strings accepted.
  def int64_arg(args, key, default)
    return [default, nil] unless args.key?(key)

    raw = args[key]
    case raw
    when Integer
      [raw, nil]
    when Float
      return [0, "#{key} must be an integer, got float #{raw}"] unless raw == raw.truncate
      if raw > 9.223372036854776e18 || raw < -9.223372036854776e18
        return [0, "#{key} value #{raw} overflows int64"]
      end

      [raw.to_i, nil]
    when String
      return [0, "invalid integer format for #{key} parameter: invalid syntax"] unless raw.match?(/\A[+-]?\d+\z/)

      [raw.to_i, nil]
    else
      [0, "unsupported type #{raw.class} for #{key} parameter"]
    end
  end
end
