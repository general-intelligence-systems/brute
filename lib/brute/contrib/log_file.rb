# frozen_string_literal: true

require "file/tail"
require "fileutils"

module Brute
  module Contrib
    # A line-oriented, append-only log file that doubles as a work queue.
    #
    # Every entry is exactly one line — newlines in the input are folded to
    # spaces on the way in — so a line is the unit of both storage and
    # retrieval. Reads are destructive: `pop` takes the newest line off the
    # end, `drain` yields every line oldest-first and empties the file.
    #
    #   log = Brute::Contrib::LogFile.new("tmp/queue.log")
    #   log.append("something happened")
    #   log.pop            # => "something happened"
    #   log.drain { |line| handle(line) }
    #
    # Safe across both threads (a mutex) and processes (an exclusive flock),
    # so several agents can share one file without losing lines.
    class LogFile < File
      include File::Tail

      def initialize(path)
        FileUtils.mkdir_p(File.dirname(path))
        super(path, File::RDWR | File::CREAT | File::APPEND)
        @mutex = Mutex.new
      end

      # Append one line. Blank (or whitespace-only) input is a no-op and
      # returns nil; otherwise returns the stripped line that was written.
      def append(line)
        strip_whitespace(line).then do |stripped_text|
          unless stripped_text.empty?
            locked do
              puts(stripped_text)
              flush
              stripped_text
            end
          end
        end
      end

      # Remove and return the newest line, or nil when the file is empty.
      def pop
        locked do
          backward(1)
          offset = tell
          gets&.chomp.tap { truncate(offset) }
        end
      end

      # Yield every line oldest-first, then empty the file. Requires a block —
      # without one there is nowhere for the lines to go, so it raises rather
      # than discarding them.
      def drain
        locked do
          if block_given?
            backward(line_count)
            each_line { |x| yield x.chomp }
            truncate(0)
          else
            raise "No block given..."
          end
        end
      end

      private

        def line_count
          rewind
          each_line.count
        end

        def strip_whitespace(line)
          line.to_s.gsub(/\r?\n/, " ").strip
        end

        def locked
          @mutex.synchronize do
            flock(File::LOCK_EX)
            yield
          ensure
            flock(File::LOCK_UN)
          end
        end
    end
  end
end

__END__

require "tmpdir"

describe "brute/contrib/log_file" do
  it "pops the last line, then nothing" do
    Dir.mktmpdir do |dir|
      log = Brute::Contrib::LogFile.new(File.join(dir, "log"))
      log.append("first")
      log.append("second")

      log.pop.should == "second"
      log.pop.should == "first"
      log.pop.should.be.nil
    end
  end

  it "keeps one entry on one line" do
    Dir.mktmpdir do |dir|
      log = Brute::Contrib::LogFile.new(File.join(dir, "log"))
      log.append("two\nlines")
      log.append("   ")

      log.pop.should == "two lines"
      log.pop.should.be.nil
    end
  end

  it "loses no line to concurrent threads" do
    Dir.mktmpdir do |dir|
      log = Brute::Contrib::LogFile.new(File.join(dir, "log"))
      4.times.map { |i| Thread.new { 50.times { |j| log.append("p#{i}-#{j}") } } }.each(&:join)

      popped = []
      4.times.map { Thread.new { while (line = log.pop) do popped << line end } }.each(&:join)

      popped.uniq.size.should == 200
      File.size(log.path).should == 0
    end
  end

  it "drains every line, oldest first, and empties the file" do
    Dir.mktmpdir do |dir|
      log = Brute::Contrib::LogFile.new(File.join(dir, "log"))
      log.append("first")
      log.append("second")
      log.append("third")

      drained = []
      log.drain { |line| drained << line }

      drained.should == ["first", "second", "third"]
      File.size(log.path).should == 0
      log.pop.should.be.nil
    end
  end

  it "refuses to drain without a block, leaving the lines alone" do
    Dir.mktmpdir do |dir|
      log = Brute::Contrib::LogFile.new(File.join(dir, "log"))
      log.append("first")
      log.append("second")

      lambda { log.drain }.should.raise(RuntimeError)

      File.read(log.path).should == "first\nsecond\n"
      log.pop.should == "second"
    end
  end

  it "keeps appending after a drain" do
    Dir.mktmpdir do |dir|
      log = Brute::Contrib::LogFile.new(File.join(dir, "log"))
      log.append("before")
      log.drain { |line| line }
      log.append("after")

      log.pop.should == "after"
      log.pop.should.be.nil
    end
  end
end
