# frozen_string_literal: true

require "json"
require "pathname"

module HermesTools
  # skill_view — progressive disclosure tier 3: full skill content.
  # Port of hermes-agent tools/skills_tool.py:1057 (local-skill path).
  #
  # Fidelity notes:
  #   - file_path reads support files (references/, templates/, scripts/…),
  #     contained to the skill directory — traversal/absolute paths refused.
  #   - Binary files are stubbed by size, never inlined.
  #   - Per-turn dedup: an identical repeat view (same skill, unchanged on
  #     disk) returns a stub instead of re-sending the content (hermes
  #     _record_skill_view/_check_skill_view_dedup, scoped here to the turn
  #     because the tool instance is per-turn).
  #   - Every view bumps view telemetry (all skills, any provenance).
  class SkillView < Brute::Tool
    description "View the content of a skill or a specific file within a skill directory."
    params({
      "type" => "object",
      "properties" => {
        "name" => { "type" => "string", "description" => "Name of the skill (e.g. 'hermes-agent')." },
        "file_path" => { "type" => "string", "description" => "Optional path to a specific file within the skill (e.g. 'references/api.md')." },
      },
      "required" => ["name"],
    })

    BINARY_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .pdf .zip .gz .tar .bin .woff .woff2 .ttf .mp3 .mp4 .mov].freeze

    def initialize(store = nil)
      @store = store
      @served = {} # name|file_path → content fingerprint (per-turn dedup)
    end

    def name = "skill_view"

    def execute(name:, file_path: nil)
      return err("Skill name is required.") if name.to_s.strip.empty?
      return err("Invalid skill name '#{name}'.") unless name =~ /\A[\w\-\/.]+\z/

      entry = @store&.find(name)
      return err("Skill '#{name}' not found. Use skills_list to see available skills.") unless entry

      skill_dir = File.dirname(entry[:path])
      target = file_path ? contained_path(skill_dir, file_path) : entry[:path]
      return err("Invalid file_path '#{file_path}' — must stay within the skill directory.") unless target
      return err("File '#{file_path}' not found in skill '#{name}'.") unless File.exist?(target)

      if BINARY_EXTENSIONS.include?(File.extname(target).downcase)
        content = "[Binary file: #{File.basename(target)}, size: #{File.size(target)} bytes]"
      else
        content = File.read(target, encoding: Encoding::UTF_8)
      end

      fingerprint = content.hash
      key = "#{name}|#{file_path}"
      if @served[key] == fingerprint
        return JSON.dump(
          "success" => true,
          "name" => name,
          "deduped" => true,
          "note" => "Skill '#{name}'#{file_path ? " (#{file_path})" : ""} was already loaded this turn and is unchanged — its content is above.",
        )
      end
      @served[key] = fingerprint

      @store.bump_view(name)

      JSON.dump(
        "success" => true,
        "name" => name,
        "category" => entry[:category],
        "content" => content,
        "linked_files" => linked_files(skill_dir, entry[:path]),
      )
    end

    private

    def err(message)
      JSON.dump("success" => false, "error" => message)
    end

    # Resolve a support-file path strictly inside the skill directory.
    def contained_path(skill_dir, file_path)
      return nil if file_path.start_with?("/", "~")

      resolved = Pathname.new(File.join(skill_dir, file_path)).cleanpath
      base = Pathname.new(skill_dir).cleanpath
      return nil unless resolved.to_s.start_with?("#{base}/")

      resolved.to_s
    end

    def linked_files(skill_dir, skill_md)
      Dir[File.join(skill_dir, "**", "*")]
        .select { |f| File.file?(f) }
        .reject { |f| f == skill_md }
        .map { |f| Pathname.new(f).relative_path_from(Pathname.new(skill_dir)).to_s }
        .sort
    end
  end
end
