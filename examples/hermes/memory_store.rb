# frozen_string_literal: true

require "fileutils"
require_relative "threat_patterns"

module Hermes
  # Bounded curated memory with file persistence — full port of hermes-agent's
  # MemoryStore (tools/memory_tool.py:148).
  #
  # Two parallel states:
  #   - @snapshot: frozen at load time, used for system prompt injection.
  #     Never mutated mid-session. Keeps the prefix cache stable.
  #   - @entries: live state, mutated by tool calls, persisted to disk.
  #     Tool responses always reflect this live state.
  #
  # Files: <dir>/MEMORY.md and <dir>/USER.md — entries joined by "\n§\n".
  class MemoryStore
    ENTRY_DELIMITER = "\n§\n"

    # Stable header prefixes — kept in lockstep with anything that needs to
    # detect a rendered block (hermes exports these for compression).
    HEADERS = {
      "memory" => "MEMORY (your personal notes)",
      "user"   => "USER PROFILE (who the user is)",
    }.freeze

    # After this many failed consolidation attempts in ONE turn, stop
    # instructing the model to retry and return a terminal "save skipped"
    # result — a failed memory side effect must never eat the turn (#42405).
    MAX_CONSOLIDATION_FAILURES_PER_TURN = 3

    # Sentinel returned by reload_target when the file EXISTS but could not be
    # read. Callers must abort the mutation rather than persist over an
    # unreadable file (that would wipe the on-disk memory).
    READ_FAILED = Object.new.freeze

    attr_reader :dir, :memory_char_limit, :user_char_limit

    def initialize(dir:, memory_char_limit: 2_200, user_char_limit: 1_375)
      @dir = dir
      @memory_char_limit = memory_char_limit
      @user_char_limit = user_char_limit
      @entries = { "memory" => [], "user" => [] }
      @snapshot = { "memory" => "", "user" => "" }
      @consolidation_failures = 0
    end

    # Reset the per-turn consolidation-failure counter (call at turn start).
    def reset_consolidation_failures!
      @consolidation_failures = 0
    end

    # Load entries from MEMORY.md and USER.md, capture the frozen
    # system-prompt snapshot. Load is lenient (an unreadable file degrades to
    # [] — nothing is written back here); mutation paths use checked reads.
    def load_from_disk
      FileUtils.mkdir_p(@dir)
      %w[memory user].each do |target|
        entries = parse_entries(read_file(path_for(target))).uniq
        @entries[target] = entries
        @snapshot[target] = render_block(target, sanitize_for_snapshot(entries, File.basename(path_for(target))))
      end
      self
    end

    # The frozen snapshot for system prompt injection — the state captured at
    # load_from_disk time, NOT the live state. nil when empty at load time.
    def format_for_system_prompt(target)
      block = @snapshot[target]
      block.nil? || block.empty? ? nil : block
    end

    def entries_for(target) = @entries[target]

    def char_count(target)
      entries = entries_for(target)
      entries.empty? ? 0 : entries.join(ENTRY_DELIMITER).length
    end

    def char_limit(target) = target == "user" ? @user_char_limit : @memory_char_limit

    # -- Mutations ----------------------------------------------------------

    # Append a new entry. Errors when it would exceed the char limit.
    def add(target:, content:)
      content = content.to_s.strip
      return { success: false, error: "Content cannot be empty." } if content.empty?

      scan_error = ThreatPatterns.first_threat_message(content)
      return { success: false, error: scan_error } if scan_error

      with_file_lock(path_for(target)) do
        # add appends, so it skips the drift guard — but only when the reload
        # actually read the file: it still rewrites the WHOLE file from parsed
        # entries, so an unreadable file must abort, not wipe (#26045 class).
        return read_failed_error(path_for(target)) if reload_target(target, skip_drift: true).equal?(READ_FAILED)

        entries = entries_for(target)
        limit = char_limit(target)

        # Reject exact duplicates.
        return success_response(target, "Entry already exists (no duplicate added).") if entries.include?(content)

        new_total = (entries + [content]).join(ENTRY_DELIMITER).length
        if new_total > limit
          current = char_count(target)
          return consolidation_failure(
            success: false,
            error: "Memory at #{fmt(current)}/#{fmt(limit)} chars. " \
                   "Adding this entry (#{content.length} chars) would exceed the limit. " \
                   "Consolidate now: use 'replace' to merge overlapping entries into " \
                   "shorter ones or 'remove' stale or less important entries (see " \
                   "current_entries below), then retry this add — all in this turn.",
            current_entries: entries,
            usage: "#{fmt(current)}/#{fmt(limit)}",
          )
        end

        entries << content
        save_to_disk(target)
      end

      success_response(target, "Entry added.")
    end

    # Find the entry containing old_text (substring) and replace it entirely.
    def replace(target:, old_text:, content:)
      old_text = old_text.to_s.strip
      content = content.to_s.strip
      return { success: false, error: "old_text cannot be empty." } if old_text.empty?
      if content.empty?
        return { success: false, error: "new_content cannot be empty. Use 'remove' to delete entries." }
      end

      scan_error = ThreatPatterns.first_threat_message(content)
      return { success: false, error: scan_error } if scan_error

      with_file_lock(path_for(target)) do
        bak = reload_target(target)
        return read_failed_error(path_for(target)) if bak.equal?(READ_FAILED)
        return drift_error(path_for(target), bak) if bak

        entries = entries_for(target)
        matches = entries.each_with_index.select { |e, _| e.include?(old_text) }

        if matches.empty?
          return consolidation_failure(
            success: false,
            error: "No entry matched '#{old_text}'. Check current_entries below and retry " \
                   "with the exact text of the entry you want to replace.",
            current_entries: entries,
          )
        end

        if matches.size > 1 && matches.map(&:first).uniq.size > 1
          return {
            success: false,
            error: "Multiple entries matched '#{old_text}'. Be more specific.",
            matches: previews(matches.map(&:first)),
          }
        end
        # All matches identical (exact duplicates) — safe to replace the first.

        idx = matches.first.last
        limit = char_limit(target)

        test = entries.dup
        test[idx] = content
        new_total = test.join(ENTRY_DELIMITER).length
        if new_total > limit
          current = char_count(target)
          return consolidation_failure(
            success: false,
            error: "Replacement would put memory at #{fmt(new_total)}/#{fmt(limit)} chars. " \
                   "Shorten the new content, or 'remove' other stale or less important " \
                   "entries to make room (see current_entries below), then retry — all " \
                   "in this turn.",
            current_entries: entries,
            usage: "#{fmt(current)}/#{fmt(limit)}",
          )
        end

        entries[idx] = content
        save_to_disk(target)
      end

      success_response(target, "Entry replaced.")
    end

    # Remove the entry containing old_text (substring).
    def remove(target:, old_text:)
      old_text = old_text.to_s.strip
      return { success: false, error: "old_text cannot be empty." } if old_text.empty?

      with_file_lock(path_for(target)) do
        bak = reload_target(target)
        return read_failed_error(path_for(target)) if bak.equal?(READ_FAILED)
        return drift_error(path_for(target), bak) if bak

        entries = entries_for(target)
        matches = entries.each_with_index.select { |e, _| e.include?(old_text) }

        if matches.empty?
          return consolidation_failure(
            success: false,
            error: "No entry matched '#{old_text}'. Check current_entries below and retry " \
                   "with the exact text of the entry you want to remove.",
            current_entries: entries,
          )
        end

        if matches.size > 1 && matches.map(&:first).uniq.size > 1
          return {
            success: false,
            error: "Multiple entries matched '#{old_text}'. Be more specific.",
            matches: previews(matches.map(&:first)),
          }
        end

        entries.delete_at(matches.first.last)
        save_to_disk(target)
      end

      success_response(target, "Entry removed.")
    end

    # Apply a sequence of add/replace/remove ops atomically: all-or-nothing,
    # budget checked against the FINAL state only. Any malformed/unmatched op
    # aborts the batch; nothing is written.
    def apply_batch(target:, operations:)
      return { success: false, error: "operations list is empty." } if operations.nil? || operations.empty?

      operations = operations.map { |op| (op || {}).transform_keys(&:to_s) }

      # Scan every add/replace content BEFORE touching disk — one poisoned op
      # rejects the whole batch.
      operations.each_with_index do |op, i|
        if %w[add replace].include?(op["action"]) && op["content"]
          scan_error = ThreatPatterns.first_threat_message(op["content"].to_s)
          return { success: false, error: "Operation #{i + 1}: #{scan_error}" } if scan_error
        end
      end

      with_file_lock(path_for(target)) do
        bak = reload_target(target)
        return read_failed_error(path_for(target)) if bak.equal?(READ_FAILED)
        return drift_error(path_for(target), bak) if bak

        working = entries_for(target).dup
        limit = char_limit(target)

        operations.each_with_index do |op, i|
          act = op["action"]
          content = op["content"].to_s.strip
          old_text = op["old_text"].to_s.strip
          pos = "Operation #{i + 1} (#{act || 'unknown'})"

          case act
          when "add"
            return batch_error(target, "#{pos}: content is required.") if content.empty?
            working << content unless working.include?(content) # idempotent — skip dupes
          when "replace"
            return batch_error(target, "#{pos}: old_text is required.") if old_text.empty?
            if content.empty?
              return batch_error(target, "#{pos}: content is required (use action='remove' to delete).")
            end
            matches = working.each_index.select { |j| working[j].include?(old_text) }
            return batch_error(target, "#{pos}: no entry matched '#{old_text}'.") if matches.empty?
            if matches.map { |j| working[j] }.uniq.size > 1
              return batch_error(target, "#{pos}: '#{old_text}' matched multiple distinct entries -- be more specific.")
            end
            working[matches.first] = content
          when "remove"
            return batch_error(target, "#{pos}: old_text is required.") if old_text.empty?
            matches = working.each_index.select { |j| working[j].include?(old_text) }
            return batch_error(target, "#{pos}: no entry matched '#{old_text}'.") if matches.empty?
            if matches.map { |j| working[j] }.uniq.size > 1
              return batch_error(target, "#{pos}: '#{old_text}' matched multiple distinct entries -- be more specific.")
            end
            working.delete_at(matches.first)
          else
            return batch_error(target, "#{pos}: unknown action. Use add, replace, or remove.")
          end
        end

        new_total = working.empty? ? 0 : working.join(ENTRY_DELIMITER).length
        if new_total > limit
          return consolidation_failure(
            success: false,
            error: "After applying all #{operations.size} operations, memory would be at " \
                   "#{fmt(new_total)}/#{fmt(limit)} chars -- over the limit. Remove or shorten more " \
                   "entries in the same batch (see current_entries below), then retry.",
            current_entries: entries_for(target),
            usage: "#{fmt(char_count(target))}/#{fmt(limit)}",
          )
        end

        @entries[target] = working
        save_to_disk(target)
      end

      success_response(target, "Applied #{operations.size} operation(s).")
    end

    private

    # -- Responses ----------------------------------------------------------

    # A successful write means the consolidation loop made progress, so the
    # per-turn failure budget resets (the cap counts consecutive failures).
    # Intentionally TERMINAL: confirms the write and tells the model to stop —
    # we do NOT echo the entries list (dumping it invites redundant re-issues).
    def success_response(target, message = nil)
      @consolidation_failures = 0
      entries = entries_for(target)
      current = char_count(target)
      limit = char_limit(target)
      pct = limit.positive? ? [100, (current.to_f / limit * 100).to_i].min : 0
      resp = {
        success: true,
        done: true,
        target: target,
        usage: "#{pct}% — #{fmt(current)}/#{fmt(limit)} chars",
        entry_count: entries.size,
        note: "Write saved. This update is complete — do not repeat it.",
      }
      resp[:message] = message if message
      resp
    end

    def consolidation_failure(response)
      @consolidation_failures += 1
      return response if @consolidation_failures <= MAX_CONSOLIDATION_FAILURES_PER_TURN

      {
        success: false,
        done: true,
        error: "Memory consolidation failed #{@consolidation_failures} times " \
               "this turn. Stop retrying memory calls — leave memory unchanged for " \
               "now and continue with your reply to the user. The fact can be saved " \
               "in a later turn.",
      }
    end

    def batch_error(target, message)
      consolidation_failure(
        success: false,
        error: "#{message} No operations were applied (batch is all-or-nothing).",
        current_entries: entries_for(target),
        usage: "#{fmt(char_count(target))}/#{fmt(char_limit(target))}",
      )
    end

    def drift_error(path, bak_path)
      {
        success: false,
        error: "Refusing to write #{File.basename(path)}: file on disk has content that " \
               "wouldn't round-trip through the memory tool (likely added by " \
               "the patch tool, a shell append, a manual edit, or a " \
               "concurrent session). A snapshot was saved to #{bak_path}. " \
               "Resolve the drift first — either rewrite the file as a clean " \
               "§-delimited list of entries, or move the extra content out — " \
               "then retry. This guard exists to prevent silent data loss " \
               "(issue #26045).",
        drift_backup: bak_path,
        remediation: "Open the .bak file, integrate the missing entries into the " \
                     "memory tool one at a time via memory(action=add, content=...), " \
                     "then remove or rewrite the original file to a clean state.",
      }
    end

    def read_failed_error(path)
      {
        success: false,
        error: "Refusing to write #{File.basename(path)}: the file exists but could " \
               "not be read (permissions or encoding). Treating it as empty would " \
               "wipe the stored memory — aborting instead. Fix read access, or move " \
               "the file aside, then retry.",
      }
    end

    def previews(entries, width: 80)
      entries.map { |e| e.length > width ? "#{e[0, width]}..." : e }
    end

    def render_block(target, entries)
      return "" if entries.empty?

      limit = char_limit(target)
      content = entries.join(ENTRY_DELIMITER)
      current = content.length
      pct = limit.positive? ? [100, (current.to_f / limit * 100).to_i].min : 0
      header = "#{HEADERS[target]} [#{pct}% — #{fmt(current)}/#{fmt(limit)} chars]"
      separator = "═" * 46
      "#{separator}\n#{header}\n#{separator}\n#{content}"
    end

    def fmt(num)
      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    # -- Filesystem ----------------------------------------------------------

    def path_for(target)
      File.join(@dir, target == "user" ? "USER.md" : "MEMORY.md")
    end

    # Exclusive lock for read-modify-write safety. Uses a separate .lock file
    # so the memory file itself can still be atomically replaced via rename.
    def with_file_lock(path)
      lock_path = "#{path}.lock"
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end

    # Re-read entries from disk into live state (called under lock).
    # Returns READ_FAILED when the file exists but is unreadable, the .bak
    # path when drift was detected, or nil on a clean reload.
    def reload_target(target, skip_drift: false)
      raw, ok = read_raw_checked(path_for(target))
      return READ_FAILED unless ok

      bak = skip_drift ? nil : detect_external_drift(target, raw)
      @entries[target] = parse_entries(raw).uniq
      bak
    end

    # Drift signals: (1) parse→serialize round-trip mismatch, (2) any single
    # entry larger than the whole-store char limit (no tool-written entry can
    # exceed it — an external writer appended free-form content). On drift,
    # snapshot to .bak.<ts> and return the path; nil when tool-shaped.
    def detect_external_drift(target, raw)
      return nil if raw.strip.empty?

      parsed = raw.split(ENTRY_DELIMITER).map(&:strip).reject(&:empty?)
      roundtrip = parsed.join(ENTRY_DELIMITER)
      max_entry_len = parsed.map(&:length).max || 0
      return nil unless raw.strip != roundtrip || max_entry_len > char_limit(target)

      bak_path = "#{path_for(target)}.bak.#{Time.now.to_i}"
      begin
        File.write(bak_path, raw, encoding: Encoding::UTF_8)
      rescue SystemCallError, IOError
        return "#{bak_path} (BACKUP FAILED — file unchanged on disk)"
      end
      bak_path
    end

    # Checked read: distinguishes unreadable from empty. An absent file is a
    # clean ["", true]; an existing-but-unreadable (or invalid-UTF-8) file is
    # ["", false] — read-modify-write callers must abort on false.
    def read_raw_checked(path)
      return ["", true] unless File.exist?(path)

      raw = File.read(path, encoding: Encoding::UTF_8)
      raw = raw.sub(/\A\uFEFF/, "") # strip BOM (utf-8-sig equivalent)
      return ["", false] unless raw.valid_encoding?

      [raw, true]
    rescue SystemCallError, IOError
      ["", false]
    end

    # Lenient read for load time only (degrades to []; nothing is written back).
    def read_file(path)
      read_raw_checked(path).first
    end

    def parse_entries(raw)
      return [] if raw.strip.empty?

      raw.split(ENTRY_DELIMITER).map(&:strip).reject(&:empty?)
    end

    def save_to_disk(target)
      FileUtils.mkdir_p(@dir)
      write_file(path_for(target), entries_for(target))
    end

    # Atomic temp-file + rename: readers always see a complete file.
    def write_file(path, entries)
      content = entries.any? ? entries.join(ENTRY_DELIMITER) : ""
      tmp = File.join(File.dirname(path), ".mem_#{File.basename(path)}.#{Process.pid}.tmp")
      File.write(tmp, content, encoding: Encoding::UTF_8)
      File.rename(tmp, path)
    rescue SystemCallError, IOError => e
      raise "Failed to write memory file #{path}: #{e.message}"
    end

    # Sanitize entries for the system-prompt snapshot only: threat-matching
    # entries become [BLOCKED: …] placeholders. Live state keeps the raw text
    # so the user can still see and remove poisoned entries.
    def sanitize_for_snapshot(entries, filename)
      entries.map do |entry|
        if entry.empty? || entry.start_with?("[BLOCKED:")
          entry
        elsif (findings = ThreatPatterns.scan_for_threats(entry, scope: "strict")).any?
          "[BLOCKED: #{filename} entry contained threat pattern(s): " \
            "#{findings.join(', ')}. Removed from system prompt; " \
            "use memory(action=remove) to delete the original.]"
        else
          entry
        end
      end
    end
  end
end
