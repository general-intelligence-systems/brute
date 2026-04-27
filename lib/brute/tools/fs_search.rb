# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/tools"
require "brute/truncation"
require "open3"

module Brute
  module Tools
    # Existing features (ref: opencode grep tool):
    #
    # 1. Global result cap — limit total matches to 100 across all files.
    # 2. Per-line truncation — truncate individual match lines longer than
    #    2000 chars via rg --max-columns with preview.
    # 3. Structured truncation message — when results are capped, append:
    #    "(Results truncated: showing 100 of N matches. Consider a more
    #    specific path or pattern.)"
    # 4. Sort results by file mtime — most-recently-modified files first,
    #    so the LLM sees the most relevant matches first.
    # 5. Return a plain string instead of a Hash.
    # 6. Align output cap with universal truncation (2000 lines / 50 KB).
    #
    class FSSearch < RubyLLM::Tool
      description "Search file contents using ripgrep (regex), or find files by glob pattern. " \
                  "Returns matching lines with file paths and line numbers."

      param :pattern, type: 'string', desc: "Regex pattern to search for in file contents", required: true
      param :path, type: 'string', desc: "Directory to search in (defaults to current working directory)", required: false
      param :glob, type: 'string', desc: "File glob filter, e.g. '*.rb', '*.{js,ts}'", required: false
      param :ignore_case, type: 'boolean', desc: "Case-insensitive search (default: false)", required: false

      def name; "fs_search"; end

      MAX_TOTAL_MATCHES = 100

      def execute(pattern:, path: nil, glob: nil, ignore_case: false)
        dir = File.expand_path(path || Dir.pwd)
        raise "Directory not found: #{dir}" unless File.directory?(dir)

        cmd = ["rg", "--line-number", "--max-columns=2000", "--max-columns-preview", "--sortr=modified"]
        cmd << "--ignore-case" if ignore_case
        cmd += ["--glob", glob] if glob
        cmd << pattern
        cmd << dir

        stdout, stderr, status = Open3.capture3(*cmd)

        output = stdout.empty? ? stderr : stdout

        # Global cap at MAX_TOTAL_MATCHES lines
        lines = output.lines
        total_matches = lines.size
        if total_matches > MAX_TOTAL_MATCHES
          output = lines.first(MAX_TOTAL_MATCHES).join
          output += "\n(Results truncated: showing 100 of #{total_matches} matches. Consider a more specific path or pattern.)"
        end

        Brute::Truncation.truncate(output)
      end
    end
  end
end

test do
  require "tmpdir"

  it "searches the current directory without error" do
    result = Brute::Tools::FSSearch.new.call(pattern: "class FSSearch", path: __dir__)
    result.should =~ /class FSSearch/
  end

  it "returns non-zero for no matches" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "empty.txt"), "nothing here\n")
      result = Brute::Tools::FSSearch.new.call(pattern: "zzz_no_match_zzz", path: dir)
      result.should.be.kind_of(String)
    end
  end

  it "returns a String, not a Hash" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "hello world\n")
      Brute::Tools::FSSearch.new.call(pattern: "hello", path: dir).should.be.kind_of(String)
    end
  end

  it "caps total results at 100 matches" do
    Dir.mktmpdir do |dir|
      150.times { |i| File.write(File.join(dir, "f#{i}.txt"), "match_me\n") }
      result = Brute::Tools::FSSearch.new.call(pattern: "match_me", path: dir)
      result.should =~ /showing.*100/i
    end
  end

  # --- Per-line truncation ---

  it "truncates long match lines with a preview" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "long.txt"), "x" * 3000 + "\n")
      result = Brute::Tools::FSSearch.new.call(pattern: "x", path: dir)
      # Each result line should be capped, not the full 3000 chars
      result.lines.select { |l| l =~ /long\.txt/ }.each do |line|
        line.size.should.be < 2200
      end
    end
  end

  # --- Sort by mtime ---

  it "shows most recently modified files first" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "old.txt"), "findme\n")
      old_time = Time.now - 1000
      File.utime(old_time, old_time, File.join(dir, "old.txt"))
      sleep 0.05
      File.write(File.join(dir, "new.txt"), "findme\n")

      result = Brute::Tools::FSSearch.new.call(pattern: "findme", path: dir)
      old_pos = result.index("old.txt")
      new_pos = result.index("new.txt")
      new_pos.should.be < old_pos
    end
  end
end
