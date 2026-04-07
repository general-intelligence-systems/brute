# frozen_string_literal: true

require "yaml"

module Brute
  # Discovers and loads SKILL.md files from standard directories.
  #
  # A skill is a markdown file with YAML frontmatter:
  #
  #   ---
  #   name: debugging
  #   description: Systematic debugging workflow for isolating and fixing bugs
  #   ---
  #
  #   When debugging, follow these steps...
  #
  # Skills are scanned from (in order):
  #   1. .brute/skills/**/SKILL.md   (project-local)
  #   2. ~/.config/brute/skills/**/SKILL.md (global)
  #
  # The directory name containing SKILL.md becomes the skill name if frontmatter
  # doesn't specify one.
  #
  module Skill
    Info = Struct.new(:name, :description, :location, :content, keyword_init: true)

    FILENAME = "SKILL.md"

    # Scan all skill directories and return an array of Info structs.
    def self.all(cwd: Dir.pwd)
      skills = {}

      scan_dirs(cwd).each do |dir|
        Dir.glob(File.join(dir, "**", FILENAME)).sort.each do |path|
          info = load(path)
          next unless info
          # First found wins (project-local overrides global)
          skills[info.name] ||= info
        end
      end

      skills.values.sort_by(&:name)
    end

    # Get a single skill by name.
    def self.get(name, cwd: Dir.pwd)
      all(cwd: cwd).detect { |s| s.name == name }
    end

    # Format skills as XML for the system prompt.
    def self.fmt(skills)
      return nil if skills.empty?

      lines = ["<available_skills>"]
      skills.each do |skill|
        lines << "  <skill>"
        lines << "    <name>#{skill.name}</name>"
        lines << "    <description>#{skill.description}</description>"
        lines << "  </skill>"
      end
      lines << "</available_skills>"
      lines.join("\n")
    end

    # Parse a SKILL.md file into an Info struct.
    # Returns nil if the file is invalid or missing required fields.
    def self.load(path)
      raw = File.read(path)
      frontmatter, content = parse_frontmatter(raw)
      return nil unless frontmatter

      name = frontmatter["name"] || File.basename(File.dirname(path))
      description = frontmatter["description"]
      return nil unless description && !description.strip.empty?

      Info.new(
        name: name.to_s.strip,
        description: description.to_s.strip,
        location: path,
        content: content.to_s.strip,
      )
    rescue => e
      warn "Failed to load skill #{path}: #{e.message}"
      nil
    end

    # Directories to scan for skills, in priority order.
    def self.scan_dirs(cwd)
      dirs = []

      # Project-local
      project = File.join(cwd, ".brute", "skills")
      dirs << project if File.directory?(project)

      # Global
      global = File.join(Dir.home, ".config", "brute", "skills")
      dirs << global if File.directory?(global)

      dirs
    end

    # Split YAML frontmatter from markdown body.
    # Returns [hash, string] or [nil, nil].
    def self.parse_frontmatter(raw)
      return [nil, nil] unless raw.start_with?("---")

      parts = raw.split(/^---\s*$/, 3)
      return [nil, nil] if parts.length < 3

      frontmatter = YAML.safe_load(parts[1])
      return [nil, nil] unless frontmatter.is_a?(Hash)

      [frontmatter, parts[2]]
    end

    private_class_method :scan_dirs, :parse_frontmatter
  end
end
