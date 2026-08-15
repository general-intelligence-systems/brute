# frozen_string_literal: true

require "fileutils"

# MemoryFiles — picoclaw's prompt-injected memory (pkg/agent/memory.go).
#
# Computes the "# Memory" prompt part every turn: MEMORY.md ("## Long-term
# Memory") + the last 3 days of memory/YYYYMM/YYYYMMDD.md daily notes
# ("## Recent Daily Notes"), sections joined with "---". Empty when both are
# absent. There are no memory tools upstream — the agent maintains the files
# with write_file/edit_file (identity rule); MemoryStore.append_today is the
# upstream helper for daily notes (auto "# YYYY-MM-DD" header on creation).
#
# env reads: workspace root. env writes: env[:metadata][:memory_part]
# (consumed by prompt.erb via the prompt context). Side effects: file reads.
class MemoryFiles
  # MemoryStore port (pkg/agent/memory.go): long-term file + daily notes.
  class Store
    def initialize(dir)
      @dir = dir
    end

    def memory_file = File.join(@dir, "MEMORY.md")

    def today_file
      today = Time.now.strftime("%Y%m%d")
      File.join(@dir, today[0, 6], "#{today}.md")
    end

    def read_long_term
      File.exist?(memory_file) ? File.read(memory_file) : ""
    end

    def write_long_term(content)
      FileUtils.mkdir_p(@dir)
      atomic_write(memory_file, content)
    end

    def read_today
      File.exist?(today_file) ? File.read(today_file) : ""
    end

    # Creates the note with a "# YYYY-MM-DD" header when absent.
    def append_today(content)
      FileUtils.mkdir_p(File.dirname(today_file))
      existing = read_today
      new_content =
        if existing.empty?
          "# #{Time.now.strftime("%Y-%m-%d")}\n\n#{content}"
        else
          "#{existing}\n#{content}"
        end
      atomic_write(today_file, new_content)
    end

    # Last N days of daily notes, joined with "---" (missing days skipped).
    def recent_daily_notes(days)
      parts = []
      days.times do |i|
        date = Time.now - i * 86_400
        date_str = date.strftime("%Y%m%d")
        path = File.join(@dir, date_str[0, 6], "#{date_str}.md")
        parts << File.read(path) if File.exist?(path)
      end
      parts.join("\n\n---\n\n")
    end

    # GetMemoryContext port.
    def prompt_part
      long_term = read_long_term
      recent = recent_daily_notes(3)
      return "" if long_term.empty? && recent.empty?

      out = +""
      out << "## Long-term Memory\n\n#{long_term}" unless long_term.empty?
      unless recent.empty?
        out << "\n\n---\n\n" unless long_term.empty?
        out << "## Recent Daily Notes\n\n#{recent}"
      end
      out
    end

    private

    def atomic_write(path, content)
      tmp = "#{path}.tmp-#{Process.pid}"
      File.write(tmp, content)
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    end
  end

  def initialize(app, dir: File.join(Dir.pwd, "memory"))
    @app = app
    @store = Store.new(dir)
  end

  def call(env)
    env[:metadata][:memory_part] = @store.prompt_part
    @app.call(env)
  end
end
