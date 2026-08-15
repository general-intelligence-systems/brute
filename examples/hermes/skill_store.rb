# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require "brute"

module Hermes
  # Skill discovery + metadata for the hermes port. Parsing reuses Brute::Skill
  # (the Agent Skills spec validator); discovery, categories, platform gating,
  # the usage-telemetry sidecar, provenance, and the protection matrix port
  # hermes-agent's tools/skills_tool.py + tools/skill_usage.py semantics.
  #
  # Layout: <dir>/<category>/<name>/SKILL.md (category = first path component;
  # skills directly under <dir> get category "custom"). Multiple dirs are
  # scanned in order — first-found-wins on name collision (local shadows
  # bundled), matching brute's precedence.
  #
  # Usage telemetry lives in <dir>/.usage.json (first dir): per-skill
  #   { use_count, view_count, patch_count, last_viewed_at, last_used_at,
  #     last_patched_at, state: active|stale|archived, pinned, created_by }
  # Tracked for EVERY skill regardless of provenance — telemetry is
  # observability, not a curation signal.
  class SkillStore
    attr_reader :dirs

    def initialize(dirs: [File.join(Dir.pwd, "skills")])
      @dirs = Array(dirs)
    end

    # All loadable skills (platform-gated, deduped by name), sorted by
    # category then name. Each entry: { name:, description:, category:, path:,
    # skill: <Brute::Skill> }.
    def all
      found = {}
      @dirs.each do |dir|
        next unless Dir.exist?(dir)

        Dir[File.join(dir, "**", "SKILL.md")].sort.each do |path|
          skill = Brute::Skill.load(path)
          next unless skill
          next unless platform_match?(skill)

          rel = Pathname.new(File.dirname(path)).relative_path_from(Pathname.new(dir)).to_s
          category = rel.include?("/") ? rel.split("/").first : (rel == "." ? "custom" : rel)
          entry = {
            name: skill.name,
            description: skill.description,
            category: category,
            path: path,
            skill: skill,
          }
          found[skill.name] ||= entry
        end
      end
      found.values.sort_by { |e| [e[:category], e[:name]] }
    end

    def find(name)
      all.find { |e| e[:name] == name.to_s }
    end

    def categories
      all.map { |e| e[:category] }.uniq.sort
    end

    # -- Platform gating ------------------------------------------------------

    def platform_match?(skill)
      platforms = skill.metadata.is_a?(Hash) ? skill.metadata["platforms"] : nil
      platforms ||= skill.metadata.is_a?(Hash) ? skill.metadata.dig("hermes", "platforms") : nil
      return true if platforms.nil? || platforms.empty?

      platforms = platforms.map(&:to_s)
      platforms.include?(host_platform)
    end

    def host_platform
      @host_platform ||= begin
        require "rbconfig"
        case RbConfig::CONFIG["host_os"]
        when /darwin/i then "macos"
        when /mswin|mingw|cygwin/i then "windows"
        else "linux"
        end
      end
    end

    # -- Usage telemetry --------------------------------------------------------

    def usage_file
      File.join(@dirs.first, ".usage.json")
    end

    def usage_records
      return {} unless File.exist?(usage_file)

      JSON.parse(File.read(usage_file, encoding: Encoding::UTF_8))
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def usage_record(name)
      usage_records[name.to_s] || {}
    end

    def bump_view(name)   = mutate_usage(name) { |r| r["view_count"] = int(r["view_count"]) + 1; r["last_viewed_at"] = now_iso }
    def bump_use(name)    = mutate_usage(name) { |r| r["use_count"] = int(r["use_count"]) + 1; r["last_used_at"] = now_iso }
    def bump_patch(name)  = mutate_usage(name) { |r| r["patch_count"] = int(r["patch_count"]) + 1; r["last_patched_at"] = now_iso }

    def set_provenance(name, created_by:)
      mutate_usage(name) { |r| r["created_by"] = created_by }
    end

    def mutate_usage(name)
      with_usage_lock do
        records = usage_records
        rec = records[name.to_s] ||= {}
        yield rec
        rec["state"] ||= "active"
        write_usage(records)
      end
    end

    # -- Protection matrix ------------------------------------------------------

    def pinned?(name) = usage_record(name)["pinned"] == true

    def curator_managed?(name)
      rec = usage_record(name)
      rec["created_by"] == "agent" || rec["agent_created"] == true
    end

    # Who may write this skill? Foreground (user present) may write anything
    # not pinned. The background review fork may only write curator-managed
    # (created_by: "agent") skills — bundled, hub-installed, pinned, and
    # user-owned skills are all refused to autonomous writers.
    def writable_by?(name, origin:)
      return false if pinned?(name) && origin == "background_review"
      return true unless origin == "background_review"

      curator_managed?(name)
    end

    private

    def int(v) = v.is_a?(Integer) && v >= 0 ? v : 0
    def now_iso = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    def with_usage_lock
      FileUtils.mkdir_p(@dirs.first)
      File.open("#{usage_file}.lock", File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end

    def write_usage(records)
      tmp = "#{usage_file}.tmp"
      File.write(tmp, JSON.pretty_generate(records), encoding: Encoding::UTF_8)
      File.rename(tmp, usage_file)
    end
  end
end
