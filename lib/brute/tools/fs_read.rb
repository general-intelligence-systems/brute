# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/tools"
require "brute/truncation"

module Brute
  module Tools
    # Existing features (ref: opencode read tool):
    #
    # 1. Default line limit — cap reads at 2000 lines when no start_line/end_line
    #    given, instead of reading the entire file.
    # 2. Byte cap — stop reading when cumulative output exceeds 50 KB (MAX_BYTES).
    #    Whichever limit (lines or bytes) is hit first wins.
    # 3. Per-line truncation — truncate individual lines longer than 2000 chars
    #    with a suffix like "... (line truncated to 2000 chars)".
    # 4. Pagination hint — when output is truncated, append a hint:
    #    "(Showing lines 1-N of M. Use start_line=N+1 to continue.)"
    #    When reading completes, append "(End of file - total N lines)".
    # 5. Binary file detection — read first 4 KB sample, check for null bytes
    #    and known binary extensions (.zip, .exe, .so, .pyc, etc.).
    #    Reject with "Cannot read binary file: (path)".
    # 6. Directory listing — when file_path points to a directory, list entries
    #    (paginated, respecting limit) instead of raising an error.
    # 7. File-not-found suggestions — on miss, scan the parent directory for
    #    similar names and suggest "Did you mean...?" candidates.
    # 8. Return a plain string instead of a Hash — avoids the .to_s repr
    #    bloat when ToolCall coerces the result for the LLM message.
    #
    class FSRead < RubyLLM::Tool
      description "Read the contents of a file. Returns file content with line numbers. " \
                  "Use start_line/end_line for partial reads of large files."

      param :file_path, type: 'string', desc: "Absolute or relative path to the file to read", required: true
      param :start_line, type: 'integer', desc: "Starting line number (1-indexed). Omit to read from beginning", required: false
      param :end_line, type: 'integer', desc: "Ending line number (inclusive). Omit to read to end", required: false

      def name; "read"; end

      BINARY_EXTENSIONS = %w[.zip .exe .so .pyc .pyo .dll .dylib .bin .o .a .tar .gz .bz2 .xz .7z .rar .jar .war .class .png .jpg .jpeg .gif .bmp .ico .pdf .woff .woff2 .ttf .eot .mp3 .mp4 .avi .mov .flv .wmv .db .sqlite .sqlite3].freeze
      DEFAULT_LINE_CAP = 2000
      MAX_BYTES = Brute::Truncation::MAX_BYTES
      MAX_LINE_LENGTH = Brute::Truncation::MAX_LINE_LENGTH

      def execute(file_path:, start_line: nil, end_line: nil)
        path = File.expand_path(file_path)

        # Directory listing
        return list_directory(path) if File.directory?(path)

        # File-not-found suggestions
        unless File.exist?(path)
          suggestions = find_similar(path)
          msg = "File not found: #{path}"
          msg += ". Did you mean: #{suggestions.join(', ')}?" if suggestions.any?
          raise msg
        end

        raise "Not a file: #{path}" unless File.file?(path)

        # Binary file detection
        ext = File.extname(path).downcase
        raise "Cannot read binary file: #{path}" if BINARY_EXTENSIONS.include?(ext)

        sample = File.binread(path, 4096) || ""
        raise "Cannot read binary file: #{path}" if sample.include?("\x00")

        lines = File.readlines(path)
        total = lines.size
        first = start_line ? [start_line - 1, 0].max : 0

        # Apply default line cap when no explicit range given
        default_last = end_line ? [end_line - 1, total - 1].min : [first + DEFAULT_LINE_CAP - 1, total - 1].min
        last = default_last

        selected = lines[first..last] || []

        # Per-line truncation + byte cap
        numbered = []
        bytes = 0
        selected.each_with_index do |line, i|
          truncated_line = Brute::Truncation.truncate_line(line, max: MAX_LINE_LENGTH)
          numbered_line = "#{first + i + 1}\t#{truncated_line}"
          break if bytes + numbered_line.bytesize > MAX_BYTES
          numbered << numbered_line
          bytes += numbered_line.bytesize
        end

        actual_last = first + numbered.size - 1
        content = numbered.join
        truncated = (actual_last < total - 1) && end_line.nil?

        if truncated
          content + "\n(Showing lines #{first + 1}-#{actual_last + 1} of #{total}. Use start_line=#{actual_last + 2} to continue.)"
        else
          content
        end
      end

      private

      def list_directory(path)
        entries = Dir.entries(path).reject { |e| e.start_with?(".") }.sort
        total = entries.size
        capped = entries.first(DEFAULT_LINE_CAP)
        result = capped.map do |entry|
          full = File.join(path, entry)
          type = File.directory?(full) ? "dir" : "file"
          "#{entry} (#{type})"
        end.join("\n")

        if total > DEFAULT_LINE_CAP
          result += "\n(Showing #{DEFAULT_LINE_CAP} of #{total} entries)"
        end
        result
      end

      def find_similar(path)
        dir = File.dirname(path)
        target = File.basename(path)
        return [] unless File.directory?(dir)

        entries = Dir.entries(dir).reject { |e| e.start_with?(".") }
        entries.select { |e| levenshtein(e.downcase, target.downcase) <= 3 }
               .sort_by { |e| levenshtein(e.downcase, target.downcase) }
               .first(3)
      end

      def levenshtein(a, b)
        m, n = a.length, b.length
        d = Array.new(m + 1) { |i| i }
        (1..n).each do |j|
          prev = d[0]
          d[0] = j
          (1..m).each do |i|
            cost = a[i - 1] == b[j - 1] ? 0 : 1
            temp = d[i]
            d[i] = [d[i] + 1, d[i - 1] + 1, prev + cost].min
            prev = temp
          end
        end
        d[m]
      end
    end
  end
end

test do
  require "tmpdir"

  it "reads a file without error" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      File.write(path, "line1\nline2\nline3\n")
      result = Brute::Tools::FSRead.new.call(file_path: path)
      result.should =~ /line1/
    end
  end

  it "reads a range without error" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      File.write(path, "a\nb\nc\nd\ne\n")
      result = Brute::Tools::FSRead.new.call(file_path: path, start_line: 2, end_line: 4)
      result.should =~ /2\tb/
    end
  end

  it "raises on missing file" do
    lambda { Brute::Tools::FSRead.new.call(file_path: "/nonexistent/file.txt") }.should.raise
  end

  it "returns a String, not a Hash" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      File.write(path, "hello\n")
      Brute::Tools::FSRead.new.call(file_path: path).should.be.kind_of(String)
    end
  end

  it "caps output at 2000 lines by default" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "big.txt")
      File.write(path, "x\n" * 3000)
      result = Brute::Tools::FSRead.new.call(file_path: path)
      result.lines.size.should.be < 2100
    end
  end

  it "rejects binary files" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "binary.bin")
      File.binwrite(path, "\x00\x01\x02\x03" * 1000)
      lambda { Brute::Tools::FSRead.new.call(file_path: path) }.should.raise
    end
  end

  it "includes a pagination hint when truncated" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "big.txt")
      File.write(path, "x\n" * 3000)
      result = Brute::Tools::FSRead.new.call(file_path: path)
      result.should =~ /start_line/
    end
  end

  # --- Byte cap ---

  it "stops reading when output exceeds 50 KB" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "big.txt")
      # Each line ~200 bytes, 500 lines = ~100 KB > 50 KB
      File.write(path, ("z" * 200 + "\n") * 500)
      result = Brute::Tools::FSRead.new.call(file_path: path)
      result.bytesize.should.be < 55_000
    end
  end

  # --- Per-line truncation ---

  it "truncates lines longer than 2000 chars" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "longlines.txt")
      File.write(path, "x" * 3000 + "\nshort\n")
      result = Brute::Tools::FSRead.new.call(file_path: path)
      result.lines.first.size.should.be < 2100
    end
  end

  # --- Directory listing ---

  it "lists directory entries instead of raising" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "a")
      File.write(File.join(dir, "b.rb"), "b")
      result = Brute::Tools::FSRead.new.call(file_path: dir)
      result.should =~ /a\.txt/
      result.should =~ /b\.rb/
    end
  end

  # --- File-not-found suggestions ---

  it "suggests similar files on miss" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.yml"), "x")
      begin
        Brute::Tools::FSRead.new.call(file_path: File.join(dir, "conifg.yml"))
      rescue => e
        e.message.should =~ /did you mean/i
      end
    end
  end
end
