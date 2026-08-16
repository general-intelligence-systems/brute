# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Hermes
  # Curator — the background skill-lifecycle gardener. Port of hermes-agent
  # agent/curator.py (+ curator_backup.py), timer-model edition: driven by a
  # per-invocation interval check instead of a daemon thread.
  #
  # Invariants (hermes AGENTS.md):
  #   * only touches curator-managed skills (created_by: "agent")
  #   * never deletes — archive (to .archive/) is the max destructive action
  #   * pinned skills are exempt from every auto-transition
  #   * a tar.gz backup precedes every run
  class Curator
    # Verbatim from agent/curator.py:417 (the umbrella-consolidation doctrine).
    REVIEW_PROMPT = <<~PROMPT
      You are running as Hermes' background skill CURATOR. This is an UMBRELLA-BUILDING consolidation pass, not a passive audit and not a duplicate-finder.

      The goal of the skill collection is a LIBRARY OF CLASS-LEVEL INSTRUCTIONS AND EXPERIENTIAL KNOWLEDGE. A collection of hundreds of narrow skills where each one captures one session's specific bug is a FAILURE of the library — not a feature. An agent searching skills matches on descriptions, not on exact names (note: long descriptions are truncated to 57 chars in the system prompt skill index — keep the trigger class in that window). One broad umbrella skill with labeled subsections beats five narrow siblings for discoverability, not the other way around.

      The right target shape is CLASS-LEVEL skills with rich SKILL.md bodies + `references/`, `templates/`, and `scripts/` subfiles for session-specific detail — not one-session-one-skill micro-entries.

      Hard rules — do not violate:
      1. DO NOT touch bundled, hub-installed, or external-dir skills. The candidate list below is already filtered to local curator-managed skills only.
      2. DO NOT delete any skill. Archiving (moving the skill's directory into .archive/) is the maximum destructive action. Archives are recoverable; deletion is not.
      3. DO NOT touch skills shown as pinned=yes. Skip them entirely.
      4. DO NOT use usage counters as a reason to skip consolidation. The counters are new and often mostly zero. Judge overlap on CONTENT, not on use_count. Corollary: 'use=0' is ALSO not a reason to PRUNE a skill. Never archive a never-used skill unless it is at least 30 days old AND its content is genuinely obsolete or fully absorbed elsewhere.
      5. DO NOT reject consolidation on the grounds that 'each skill has a distinct trigger'. Pairwise distinctness is the wrong bar. The right bar is: 'would a human maintainer write this as N separate skills, or as one skill with N labeled subsections?' When the answer is the latter, merge.

      How to work — not optional:
      1. Scan the full candidate list. Identify PREFIX CLUSTERS (skills sharing a first word or domain keyword).
      2. For each cluster with 2+ members, ask: 'what is the UMBRELLA CLASS these skills all serve?' Pick (or create) the umbrella and absorb the siblings into it.
      3. Three ways to consolidate — use the right one per cluster:
         a. MERGE INTO EXISTING UMBRELLA — patch it to add a labeled section per sibling's unique insight, then archive the siblings.
         b. CREATE A NEW UMBRELLA SKILL.md — skill_manage action=create, class-level, short labeled subsections. Archive the absorbed siblings.
         c. DEMOTE TO REFERENCES/TEMPLATES/SCRIPTS — move narrow-but-valuable content into the umbrella's support directory (references/<topic>.md, templates/<name>.<ext>, scripts/<name>.<ext>), then archive the old sibling.
    PROMPT

    DEFAULTS = {
      "enabled" => false,
      "interval_hours" => 24,
      "stale_after_days" => 7,
      "archive_after_days" => 14,
      "backup" => true,
    }.freeze

    attr_reader :config

    def initialize(store, config_path: File.join(Dir.pwd, "curator.json"), review_runner: nil)
      @store = store
      @config_path = config_path
      @review_runner = review_runner
      @config = DEFAULTS.merge(load_config)
    end

    def enabled? = @config["enabled"]

    # The per-invocation check: run when enabled and the interval elapsed.
    def maybe_run(now: Time.now)
      return false unless enabled?

      last = @config["last_run_at"].to_f
      return false if now.to_f - last < @config["interval_hours"] * 3600

      run(now: now)
    end

    # A full pass: backup → deterministic transitions → LLM review (if wired).
    def run(now: Time.now)
      backup if @config["backup"]
      transitions = apply_transitions(now: now)
      review = @review_runner ? @review_runner.call(self) : nil
      @config["last_run_at"] = now.to_f
      save_config
      { transitions: transitions, review: review }
    end

    # The candidate list for the review pass (curator-managed only).
    def candidates
      @store.all.filter_map do |entry|
        rec = @store.usage_record(entry[:name])
        next unless @store.curator_managed?(entry[:name])

        entry.merge(
          pinned: @store.pinned?(entry[:name]),
          state: rec["state"] || "active",
          use_count: rec["use_count"] || 0,
          view_count: rec["view_count"] || 0,
          patch_count: rec["patch_count"] || 0,
        )
      end
    end

    def candidate_list
      candidates.map do |c|
        "- #{c[:name]} (category=#{c[:category]}, pinned=#{c[:pinned] ? 'yes' : 'no'}, state=#{c[:state]}, use=#{c[:use_count]}, views=#{c[:view_count]}): #{c[:description]}"
      end.join("\n")
    end

    # Usage-based state transitions: active → stale → archived.
    def apply_transitions(now: Time.now)
      stale_cutoff = now - @config["stale_after_days"] * 86_400
      archive_cutoff = now - @config["archive_after_days"] * 86_400
      done = []

      candidates.each do |c|
        next if c[:pinned]

        age = last_activity(c[:name])
        next unless age

        rec = @store.usage_record(c[:name])
        state = rec["state"] || "active"
        if age < archive_cutoff && state != "archived"
          archive(c[:name])
          done << "archived: #{c[:name]}"
        elsif age < stale_cutoff && state == "active"
          @store.mutate_usage(c[:name]) { |r| r["state"] = "stale" }
          done << "stale: #{c[:name]}"
        end
      end
      done
    end

    def archive(name)
      entry = @store.find(name) or return false
      src = File.dirname(entry[:path])
      dest_dir = File.join(@store.dirs.first, ".archive")
      FileUtils.mkdir_p(dest_dir)
      FileUtils.mv(src, File.join(dest_dir, name))
      @store.mutate_usage(name) { |r| r["state"] = "archived" }
      true
    end

    def restore(name)
      archive_dir = File.join(@store.dirs.first, ".archive", name)
      return false unless Dir.exist?(archive_dir)

      FileUtils.mv(archive_dir, File.join(@store.dirs.first, "custom", name))
      @store.mutate_usage(name) { |r| r["state"] = "active" }
      true
    end

    # -- internals ---------------------------------------------------------------

    def last_activity(name)
      rec = @store.usage_record(name)
      stamps = [rec["last_viewed_at"], rec["last_used_at"], rec["last_patched_at"]].compact
      times = stamps.filter_map { |s| (Time.parse(s) rescue nil) }
      return times.max unless times.empty?

      entry = @store.find(name)
      entry ? File.mtime(entry[:path]) : nil
    end

    def backup
      dir = @store.dirs.first
      return unless Dir.exist?(dir)

      dest = File.join(dir, ".archive", "backups")
      FileUtils.mkdir_p(dest)
      system("tar", "-czf", File.join(dest, "skills-#{Time.now.strftime('%Y%m%d-%H%M%S')}.tar.gz"),
             "-C", dir, "--exclude", ".archive", ".")
    end

    def load_config
      return {} unless File.exist?(@config_path)

      JSON.parse(File.read(@config_path))
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def save_config
      File.write("#{@config_path}.tmp", JSON.pretty_generate(@config))
      File.rename("#{@config_path}.tmp", @config_path)
    end
  end
end
