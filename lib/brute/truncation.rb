# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "fileutils"
require "securerandom"

module Brute
  # Universal tool output truncation.
  #
  # Every tool result passes through Truncation.truncate() before entering
  # the LLM context. This is the primary guard against context window
  # explosion — even if a tool has no internal limits, this module caps
  # the output to a safe size.
  #
  # Existing features (ref: opencode truncate.ts):
  #
  # 1. Line + byte dual cap — truncate when output exceeds MAX_LINES
  #    (2000) or MAX_BYTES (50 KB), whichever is hit first.
  # 2. Head mode (default) — keep the first N lines / bytes. Used for
  #    most tool output where the beginning is most relevant.
  # 3. Tail mode — keep the last N lines / bytes. Used for shell output
  #    where errors and summaries appear at the end.
  # 4. Overflow to disk — when truncating, write the full text to a file
  #    under TRUNCATION_DIR (e.g. ~/.local/share/brute/tool-output/).
  #    Return a preview + hint pointing to the saved file.
  # 5. Hint message — when truncated, append a contextual hint:
  #    "Full output saved to: <path>. Use Read with offset/limit to
  #    view specific sections."
  # 6. Configurable limits — allow overriding MAX_LINES / MAX_BYTES
  #    via per-call options.
  # 7. Retention cleanup — purge saved output files older than a
  #    configurable retention period from a truncation directory.
  # 8. Per-line truncation — truncate individual lines longer than
  #    MAX_LINE_LENGTH (2000 chars) with a suffix.
  #
  module Truncation
    MAX_LINES = 2000
    MAX_BYTES = 50 * 1024 # 50 KB
    MAX_LINE_LENGTH = 2000
    TRUNCATION_MARKER = "[Output truncated:"

    TRUNCATION_DIR = File.join(Dir.home, ".local", "share", "brute", "tool-output")

    # Truncate text to fit within line and byte limits.
    #
    # Returns the text unchanged if it fits. Otherwise returns a
    # truncated preview with a hint message.
    #
    # @param text [String] the tool output to truncate
    # @param max_lines [Integer] maximum number of lines to keep
    # @param max_bytes [Integer] maximum byte size to keep
    # @param direction [:head, :tail] which end to keep
    # @param truncation_dir [String, nil] directory to save full output when truncating
    # @return [String] the (possibly truncated) text
    #
    def self.truncate(text, max_lines: MAX_LINES, max_bytes: MAX_BYTES, direction: :head, truncation_dir: nil)
      return text if text.nil? || text.empty?

      # Per-line truncation first — cap individual lines
      lines = text.lines.map { |line| truncate_line(line) }
      text = lines.join

      return text if lines.size <= max_lines && text.bytesize <= max_bytes

      # Determine how many lines we can keep within both caps
      kept = direction == :tail ? lines.last(max_lines) : lines.first(max_lines)

      # Enforce byte cap
      result_lines = []
      bytes = 0
      kept.each do |line|
        break if bytes + line.bytesize > max_bytes
        result_lines << line
        bytes += line.bytesize
      end

      result = result_lines.join
      total = lines.size
      shown = result_lines.size

      # Overflow to disk — save the full output so it can be inspected later
      saved_path = save_to_disk(text, truncation_dir)

      hint = "\n#{TRUNCATION_MARKER} showing #{shown} of #{total} lines]"
      if saved_path
        hint += "\nFull output saved to: #{saved_path}. Use Read with offset/limit to view specific sections."
      end
      result + hint
    end

    # Check whether text already contains a truncation marker.
    def self.already_truncated?(text)
      text.include?(TRUNCATION_MARKER)
    end

    # Truncate a single line if it exceeds MAX_LINE_LENGTH.
    def self.truncate_line(line, max: MAX_LINE_LENGTH)
      return line if line.length <= max
      line[0, max] + "... (line truncated to #{max} chars)\n"
    end

    # Purge files older than retention_days from the given directory.
    def self.cleanup!(dir, retention_days: 7)
      return unless File.directory?(dir)
      cutoff = Time.now - (retention_days * 86400)
      Dir.glob(File.join(dir, "*")).each do |path|
        File.delete(path) if File.file?(path) && File.mtime(path) < cutoff
      end
    end

    # Save text to a file in truncation_dir. Returns the file path, or nil.
    def self.save_to_disk(text, truncation_dir)
      dir = truncation_dir || TRUNCATION_DIR
      return nil unless dir
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "tool_#{SecureRandom.hex(8)}.txt")
      File.write(path, text)
      path
    rescue => _e
      nil
    end
    private_class_method :save_to_disk
  end
end

test do
  require "tmpdir"
  require "fileutils"

  it "returns short text unchanged" do
    Brute::Truncation.truncate("hello world").should == "hello world"
  end

  it "truncates text exceeding 2000 lines" do
    big = "line\n" * 3000
    result = Brute::Truncation.truncate(big)
    result.lines.size.should.be < 2100
  end

  it "includes a hint when truncated" do
    big = "line\n" * 3000
    Brute::Truncation.truncate(big).should =~ /truncated/i
  end

  # --- Per-line truncation ---

  it "truncates individual lines longer than MAX_LINE_LENGTH" do
    long_line = "x" * 3000 + "\n"
    result = Brute::Truncation.truncate(long_line)
    result.lines.first.size.should.be < 2100
  end

  it "adds a suffix to truncated lines" do
    long_line = "x" * 3000 + "\n"
    result = Brute::Truncation.truncate(long_line)
    result.should =~ /truncated/i
  end

  # --- Overflow to disk ---

  it "saves full output to disk when truncating" do
    Dir.mktmpdir do |dir|
      big = "line\n" * 3000
      result = Brute::Truncation.truncate(big, truncation_dir: dir)
      files = Dir.glob(File.join(dir, "*"))
      files.size.should == 1
      File.read(files.first).should == big
    end
  end

  it "includes saved file path in hint" do
    Dir.mktmpdir do |dir|
      big = "line\n" * 3000
      result = Brute::Truncation.truncate(big, truncation_dir: dir)
      result.should =~ /Full output saved to:/
    end
  end

  it "does not save to disk when not truncated" do
    Dir.mktmpdir do |dir|
      result = Brute::Truncation.truncate("short\n", truncation_dir: dir)
      Dir.glob(File.join(dir, "*")).size.should == 0
    end
  end

  # --- Configurable limits ---

  it "accepts custom max_lines" do
    text = "line\n" * 50
    result = Brute::Truncation.truncate(text, max_lines: 10)
    result.lines.count { |l| l.strip == "line" }.should.be <= 10
  end

  it "accepts custom max_bytes" do
    text = "line\n" * 50
    result = Brute::Truncation.truncate(text, max_bytes: 20)
    result.should =~ /truncated/i
  end

  # --- Retention cleanup ---

  it "purges files older than retention period" do
    Dir.mktmpdir do |dir|
      old_file = File.join(dir, "old_output.txt")
      File.write(old_file, "old content")
      # Backdate the file to 8 days ago
      old_time = Time.now - (8 * 86400)
      File.utime(old_time, old_time, old_file)

      new_file = File.join(dir, "new_output.txt")
      File.write(new_file, "new content")

      Brute::Truncation.cleanup!(dir, retention_days: 7)
      File.exist?(old_file).should == false
      File.exist?(new_file).should == true
    end
  end
end
