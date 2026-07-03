# frozen_string_literal: true

require "yaml"

require "bundler/setup"
require "brute"

module Brute
  # Discovers, validates, and loads SKILL.md files from standard directories.
  #
  # A skill is a directory containing a SKILL.md markdown file with YAML
  # frontmatter:
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
  # Parsing and validation mirror the Agent Skills specification
  # (https://agentskills.io/specification) and its reference validator
  # (https://github.com/agentskills/agentskills/tree/main/skills-ref). A skill
  # whose frontmatter violates a rule is skipped with a stderr warning naming
  # the violated rule, never raised.
  #
  module Skill
    Info = Struct.new(
      :name, :description, :location, :content,
      :license, :compatibility, :metadata, :allowed_tools,
      keyword_init: true,
    )

    FILENAME = "SKILL.md"

    # Frontmatter keys permitted by the spec. Anything else is a violation.
    ALLOWED_FIELDS = %w[name description license allowed-tools metadata compatibility].freeze

    MAX_NAME_LENGTH = 64
    MAX_DESCRIPTION_LENGTH = 1024
    MAX_COMPATIBILITY_LENGTH = 500

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

    # Parse and validate a SKILL.md file into an Info struct.
    # Returns nil (with a stderr warning) if the file is invalid.
    def self.load(path)
      raw = File.read(path)
      frontmatter, content = parse_frontmatter(path, raw)
      return nil unless frontmatter

      dir_name = File.basename(File.dirname(path))
      # Spec requires `name`; brute keeps the convenience of defaulting to the
      # directory name when omitted (which trivially satisfies the dir-match rule).
      frontmatter = { "name" => dir_name }.merge(frontmatter) unless frontmatter.key?("name")

      # Unknown fields are a soft violation: warn and drop them rather than
      # reject the skill. The reference validator hard-fails here, but a runtime
      # loader must tolerate vendor/forward extensions (e.g. `tags`), which real
      # published skills carry, instead of silently dropping the whole skill.
      extra = frontmatter.keys - ALLOWED_FIELDS
      warn "Skill #{path} has unexpected frontmatter fields (ignored): #{extra.sort.join(', ')}" unless extra.empty?

      errors = validate(frontmatter, dir_name)
      unless errors.empty?
        warn "Skipping invalid skill #{path}: #{errors.join('; ')}"
        return nil
      end

      Info.new(
        name: frontmatter["name"].to_s.strip,
        description: frontmatter["description"].to_s.strip,
        location: path,
        content: content.to_s.strip,
        license: frontmatter["license"]&.to_s,
        compatibility: frontmatter["compatibility"]&.to_s,
        metadata: frontmatter["metadata"],
        allowed_tools: parse_allowed_tools(frontmatter["allowed-tools"]),
      )
    rescue => e
      warn "Failed to load skill #{path}: #{e.message}"
      nil
    end

    # Validate frontmatter against the spec. Returns an array of error strings
    # (empty means valid), each naming the violated rule.
    def self.validate(frontmatter, dir_name)
      errors = []

      errors.concat(validate_name(frontmatter["name"], dir_name))
      errors.concat(validate_description(frontmatter["description"]))

      if frontmatter.key?("compatibility")
        compatibility = frontmatter["compatibility"]
        if !compatibility.is_a?(String)
          errors << "'compatibility' must be a string"
        elsif compatibility.length > MAX_COMPATIBILITY_LENGTH
          errors << "'compatibility' exceeds #{MAX_COMPATIBILITY_LENGTH} characters"
        end
      end

      errors
    end

    def self.validate_name(name, dir_name)
      return ["missing required field 'name'"] unless name.is_a?(String) && !name.strip.empty?

      name = name.strip.unicode_normalize(:nfkc)
      errors = []
      errors << "'name' exceeds #{MAX_NAME_LENGTH} characters" if name.length > MAX_NAME_LENGTH
      errors << "'name' must be lowercase" if name != name.downcase
      errors << "'name' cannot start or end with a hyphen" if name.start_with?("-") || name.end_with?("-")
      errors << "'name' cannot contain consecutive hyphens" if name.include?("--")
      errors << "'name' may only contain letters, digits, and hyphens" unless name.match?(/\A[\p{Alnum}\-]+\z/)
      errors << "directory name '#{dir_name}' must match skill name '#{name}'" if dir_name.unicode_normalize(:nfkc) != name
      errors
    end

    def self.validate_description(description)
      return ["missing required field 'description'"] unless description.is_a?(String) && !description.strip.empty?
      return ["'description' exceeds #{MAX_DESCRIPTION_LENGTH} characters"] if description.length > MAX_DESCRIPTION_LENGTH

      []
    end

    # `allowed-tools` is an experimental, space-separated list of tool names.
    def self.parse_allowed_tools(value)
      return nil if value.nil?

      value.to_s.split(/\s+/).reject(&:empty?)
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
    def self.parse_frontmatter(path, raw)
      return [nil, nil] unless raw.start_with?("---")

      parts = raw.split(/^---\s*$/, 3)
      return [nil, nil] if parts.length < 3

      frontmatter = YAML.safe_load(parts[1])
      return [nil, nil] unless frontmatter.is_a?(Hash)

      [frontmatter, parts[2]]
    rescue => e
      warn "Failed to parse frontmatter in #{path}: #{e.message}"
      [nil, nil]
    end

    private_class_method :scan_dirs, :parse_frontmatter,
                         :validate, :validate_name, :validate_description, :parse_allowed_tools
  end
end

__END__

describe "brute/skill" do
  require "tmpdir"
  require "fileutils"

  def make_skill_dir(root, dir_name, frontmatter, body: "Body.")
    dir = File.join(root, ".brute", "skills", dir_name)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "SKILL.md")
    File.write(path, "---\n#{frontmatter}\n---\n\n#{body}\n")
    path
  end

  it "loads a valid skill" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "debugging", "name: debugging\ndescription: Debug things")
      info = Brute::Skill.load(path)
      info.name.should == "debugging"
      info.description.should == "Debug things"
    end
  end

  it "defaults the name to the directory when omitted" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "deploy", "description: Deploy things")
      Brute::Skill.load(path).name.should == "deploy"
    end
  end

  it "skips a skill whose name does not match its directory" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "deploy", "name: shipit\ndescription: Ship it")
      Brute::Skill.load(path).should.be.nil
    end
  end

  it "skips a skill with an uppercase name" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "Deploy", "name: Deploy\ndescription: Deploy")
      Brute::Skill.load(path).should.be.nil
    end
  end

  it "skips a skill with consecutive hyphens in the name" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "a--b", "name: a--b\ndescription: nope")
      Brute::Skill.load(path).should.be.nil
    end
  end

  it "skips a skill without a description" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "nodesc", "name: nodesc")
      Brute::Skill.load(path).should.be.nil
    end
  end

  it "loads a skill with an unexpected frontmatter field, dropping the extra" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "extra", "name: extra\ndescription: x\ntags: [a, b]")
      info = Brute::Skill.load(path)
      info.name.should == "extra"
      info.respond_to?(:tags).should.be.false
    end
  end

  it "parses optional spec fields" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(
        root, "full",
        "name: full\ndescription: x\nlicense: MIT\ncompatibility: claude\nallowed-tools: read shell\nmetadata:\n  team: core",
      )
      info = Brute::Skill.load(path)
      info.license.should == "MIT"
      info.compatibility.should == "claude"
      info.allowed_tools.should == %w[read shell]
      info.metadata.should == { "team" => "core" }
    end
  end

  it "skips a skill whose description exceeds the length bound" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "long", "name: long\ndescription: #{"x" * 1025}")
      Brute::Skill.load(path).should.be.nil
    end
  end
end
