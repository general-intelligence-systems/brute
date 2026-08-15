# frozen_string_literal: true

module PrimeAgent
  # Truncation utilities for tool outputs — the port of prime-agent's
  # packages/coding-agent/src/core/tools/truncate.ts, defaults and semantics
  # verbatim:
  #
  # Two independent limits, whichever is hit first: line limit (2000) and
  # byte limit (50 KB). Never returns partial lines — except the tail
  # truncation edge case, where a single last line exceeding the byte cap is
  # kept partially (skipped forward to a valid UTF-8 character boundary).
  #
  # Pure stdlib; no brute dependency.
  module Truncate
    DEFAULT_MAX_LINES = 2000
    DEFAULT_MAX_BYTES = 50 * 1024 # 50KB
    GREP_MAX_LINE_LENGTH = 500 # max chars per grep match line

    # Mirrors truncate.ts's TruncationResult. truncated_by is "lines",
    # "bytes", or nil when not truncated.
    Result = Data.define(
      :content, :truncated, :truncated_by, :total_lines, :total_bytes,
      :output_lines, :output_bytes, :last_line_partial,
      :first_line_exceeds_limit, :max_lines, :max_bytes
    )

    # Mirrors truncate.ts's truncateLine return.
    LineResult = Data.define(:text, :was_truncated)

    module_function

    # Format bytes as a human-readable size (formatSize).
    def format_size(bytes)
      if bytes < 1024
        "#{bytes}B"
      elsif bytes < 1024 * 1024
        "#{(bytes / 1024.0).round(1)}KB"
      else
        "#{(bytes / (1024.0 * 1024)).round(1)}MB"
      end
    end

    # Truncate from the head (keep the first N lines/bytes) — for file reads
    # where the beginning matters. Never returns partial lines; when the
    # FIRST line alone exceeds the byte limit the content is empty and
    # first_line_exceeds_limit is true.
    def truncate_head(content, max_lines: DEFAULT_MAX_LINES, max_bytes: DEFAULT_MAX_BYTES)
      total_bytes = content.bytesize
      # split with -1 keeps trailing empty fields, matching TS String#split.
      lines = content.split("\n", -1)
      total_lines = lines.length

      if total_lines <= max_lines && total_bytes <= max_bytes
        return Result.new(
          content: content, truncated: false, truncated_by: nil,
          total_lines: total_lines, total_bytes: total_bytes,
          output_lines: total_lines, output_bytes: total_bytes,
          last_line_partial: false, first_line_exceeds_limit: false,
          max_lines: max_lines, max_bytes: max_bytes,
        )
      end

      if lines[0].bytesize > max_bytes
        return Result.new(
          content: "", truncated: true, truncated_by: "bytes",
          total_lines: total_lines, total_bytes: total_bytes,
          output_lines: 0, output_bytes: 0,
          last_line_partial: false, first_line_exceeds_limit: true,
          max_lines: max_lines, max_bytes: max_bytes,
        )
      end

      output = []
      output_bytes = 0
      truncated_by = "lines"
      lines.each_with_index do |line, i|
        break if i >= max_lines

        line_bytes = line.bytesize + (i > 0 ? 1 : 0) # +1 for the newline
        if output_bytes + line_bytes > max_bytes
          truncated_by = "bytes"
          break
        end

        output << line
        output_bytes += line_bytes
      end
      truncated_by = "lines" if output.length >= max_lines && output_bytes <= max_bytes

      output_content = output.join("\n")
      Result.new(
        content: output_content, truncated: true, truncated_by: truncated_by,
        total_lines: total_lines, total_bytes: total_bytes,
        output_lines: output.length, output_bytes: output_content.bytesize,
        last_line_partial: false, first_line_exceeds_limit: false,
        max_lines: max_lines, max_bytes: max_bytes,
      )
    end

    # Truncate from the tail (keep the last N lines/bytes) — for shell output
    # where the end matters (errors, final results). May return a partial
    # first line when the original's last line alone exceeds the byte limit.
    def truncate_tail(content, max_lines: DEFAULT_MAX_LINES, max_bytes: DEFAULT_MAX_BYTES)
      total_bytes = content.bytesize
      lines = content.split("\n", -1)
      total_lines = lines.length

      if total_lines <= max_lines && total_bytes <= max_bytes
        return Result.new(
          content: content, truncated: false, truncated_by: nil,
          total_lines: total_lines, total_bytes: total_bytes,
          output_lines: total_lines, output_bytes: total_bytes,
          last_line_partial: false, first_line_exceeds_limit: false,
          max_lines: max_lines, max_bytes: max_bytes,
        )
      end

      output = []
      output_bytes = 0
      truncated_by = "lines"
      last_line_partial = false

      i = lines.length - 1
      while i >= 0 && output.length < max_lines
        line = lines[i]
        line_bytes = line.bytesize + (output.empty? ? 0 : 1) # +1 for the newline

        if output_bytes + line_bytes > max_bytes
          truncated_by = "bytes"
          # Edge case: no lines kept yet and this line exceeds maxBytes —
          # keep the END of the line (partial), UTF-8 boundary safe.
          if output.empty?
            truncated_line = truncate_string_to_bytes_from_end(line, max_bytes)
            output.unshift(truncated_line)
            output_bytes = truncated_line.bytesize
            last_line_partial = true
          end
          break
        end

        output.unshift(line)
        output_bytes += line_bytes
        i -= 1
      end
      truncated_by = "lines" if output.length >= max_lines && output_bytes <= max_bytes

      output_content = output.join("\n")
      Result.new(
        content: output_content, truncated: true, truncated_by: truncated_by,
        total_lines: total_lines, total_bytes: total_bytes,
        output_lines: output.length, output_bytes: output_content.bytesize,
        last_line_partial: last_line_partial, first_line_exceeds_limit: false,
        max_lines: max_lines, max_bytes: max_bytes,
      )
    end

    # Truncate a string to fit within a byte limit, keeping the END, without
    # splitting a multi-byte UTF-8 character (truncateStringToBytesFromEnd).
    def truncate_string_to_bytes_from_end(str, max_bytes)
      bytes = str.bytes
      return str if bytes.length <= max_bytes

      start = bytes.length - max_bytes
      start += 1 while start < bytes.length && (bytes[start] & 0xC0) == 0x80
      bytes[start..].pack("C*").force_encoding(Encoding::UTF_8)
    end

    # Truncate a single line to max_chars, adding the [truncated] suffix
    # (truncateLine — used for grep match lines upstream).
    def truncate_line(line, max_chars: GREP_MAX_LINE_LENGTH)
      return LineResult.new(text: line, was_truncated: false) if line.length <= max_chars

      LineResult.new(text: "#{line[0...max_chars]}... [truncated]", was_truncated: true)
    end
  end
end

__END__

describe "prime_agent/truncate" do
  T = PrimeAgent::Truncate

  it "passes content through when within both limits" do
    result = T.truncate_head("a\nb\nc")
    result.truncated.should.be.false
    result.truncated_by.should.be.nil
    result.content.should == "a\nb\nc"
    result.total_lines.should == 3
    result.output_lines.should == 3
  end

  it "truncate_head keeps the first N lines" do
    result = T.truncate_head((1..5).map(&:to_s).join("\n"), max_lines: 3)
    result.content.should == "1\n2\n3"
    result.truncated_by.should == "lines"
    result.output_lines.should == 3
  end

  it "truncate_head stops at the byte limit without partial lines" do
    result = T.truncate_head("aaaa\nbbbb\ncccc", max_bytes: 10)
    result.content.should == "aaaa\nbbbb" # 4 + 1 + 4 = 9 bytes; +5 more would exceed 10
    result.truncated_by.should == "bytes"
    result.last_line_partial.should.be.false
  end

  it "truncate_head returns empty with first_line_exceeds_limit when line 1 is over the byte cap" do
    result = T.truncate_head("x" * 100 + "\nshort", max_bytes: 50)
    result.content.should == ""
    result.first_line_exceeds_limit.should.be.true
    result.truncated_by.should == "bytes"
    result.output_lines.should == 0
  end

  it "truncate_tail keeps the last N lines" do
    result = T.truncate_tail((1..5).map(&:to_s).join("\n"), max_lines: 2)
    result.content.should == "4\n5"
    result.truncated_by.should == "lines"
  end

  it "truncate_tail keeps the END of an over-long last line, on a UTF-8 boundary" do
    line = "abc" + "é" * 40 # é is 2 bytes in UTF-8
    result = T.truncate_tail(line, max_bytes: 21)
    result.last_line_partial.should.be.true
    result.content.bytesize.should <= 21
    result.content.encoding.should == Encoding::UTF_8
    result.content.valid_encoding?.should.be.true
    result.content.should.end_with "é"
  end

  it "truncate_tail keeps whole lines within the byte cap" do
    result = T.truncate_tail("aaaa\nbbbb\ncccc", max_bytes: 10)
    result.content.should == "bbbb\ncccc"
    result.truncated_by.should == "bytes"
  end

  it "truncate_line clips with the [truncated] suffix" do
    T.truncate_line("short").was_truncated.should.be.false
    result = T.truncate_line("x" * 600)
    result.was_truncated.should.be.true
    result.text.should == "#{"x" * 500}... [truncated]"
  end

  it "format_size matches upstream formatting" do
    T.format_size(512).should == "512B"
    T.format_size(50 * 1024).should == "50.0KB"
    T.format_size(2 * 1024 * 1024).should == "2.0MB"
  end
end
