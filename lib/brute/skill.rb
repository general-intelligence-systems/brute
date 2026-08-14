# frozen_string_literal: true

require "yaml"

require "bundler/setup"
require "brute"

module Brute
  # A single skill: metadata plus the address of its SKILL.md on disk.
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
  # The object is a value object — it carries the parsed frontmatter, the
  # body, and the file location, nothing else. Modeled on prime-agent's
  # BaseSkill (packages/coding-agent/src/core/skills.ts).
  #
  # Discovery is class-level and caller-side: Skill.all scans (in order)
  #   1. <cwd>/.brute/skills/**/SKILL.md   (project-local, :project)
  #   2. ~/.config/brute/skills/**/SKILL.md (global, :user)
  #   3. explicit paths: (dirs or .md files, :path)
  #
  # First found wins on name collisions (with a stderr warning naming winner
  # and loser), and the same file reached twice via symlinks is skipped.
  #
  # Parsing and validation mirror the Agent Skills specification
  # (https://agentskills.io/specification). A skill whose frontmatter violates
  # a rule is skipped with a stderr warning naming the rule — never raised.
  class Skill
    attr_reader :name, :description, :file_path, :base_dir, :content,
                :source, :license, :compatibility, :metadata, :allowed_tools

    FILENAME = "SKILL.md"

    # Frontmatter keys permitted by the spec. Anything else is a violation.
    ALLOWED_FIELDS = %w[name description license allowed-tools metadata compatibility disable-model-invocation].freeze

    MAX_NAME_LENGTH = 64
    MAX_DESCRIPTION_LENGTH = 1024
    MAX_COMPATIBILITY_LENGTH = 500

    def initialize(name:, description:, file_path:, content: nil, source: :path,
                   license: nil, compatibility: nil, metadata: nil,
                   allowed_tools: nil, disable_model_invocation: false)
      @name = name
      @description = description
      @file_path = file_path
      @base_dir = File.dirname(file_path)
      @content = content
      @source = source
      @license = license
      @compatibility = compatibility
      @metadata = metadata
      @allowed_tools = allowed_tools
      @disable_model_invocation = disable_model_invocation
    end

    # Hidden from the prompt listing (explicit invocation only), but still
    # handed to the agent as an object.
    def disable_model_invocation? = @disable_model_invocation

    # Back-compat alias (Tools::SkillLoad era).
    def location = file_path

    # Parse and validate a SKILL.md file into a Skill.
    # Returns nil (with a stderr warning) if the file is invalid.
    def self.load(path, source: :path)
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

      new(
        name: frontmatter["name"].to_s.strip,
        description: frontmatter["description"].to_s.strip,
        file_path: path,
        content: content.to_s.strip,
        source: source,
        license: frontmatter["license"]&.to_s,
        compatibility: frontmatter["compatibility"]&.to_s,
        metadata: frontmatter["metadata"],
        allowed_tools: parse_allowed_tools(frontmatter["allowed-tools"]),
        disable_model_invocation: frontmatter["disable-model-invocation"] == true,
      )
    rescue => e
      warn "Failed to load skill #{path}: #{e.message}"
      nil
    end

    # Scan all skill directories and return an array of Skills, sorted by name.
    #
    # Precedence is first-found-wins: project-local overrides global overrides
    # explicit paths. Name collisions warn to stderr naming winner and loser;
    # the same file reached via different symlinks is loaded only once.
    def self.all(cwd: Dir.pwd, paths: [])
      skills = {}
      seen_files = {}

      add = lambda do |path, source|
        skill = load(path, source: source)
        return unless skill

        real = realpath(path)
        return if seen_files[real]

        if (winner = skills[skill.name])
          warn "Skill name collision: '#{skill.name}' at #{path} ignored; " \
               "already loaded from #{winner.file_path}"
          return
        end

        seen_files[real] = true
        skills[skill.name] = skill
      end

      project = File.join(cwd, ".brute", "skills")
      glob(project) { |path| add.call(path, :project) }

      global = File.join(Dir.home, ".config", "brute", "skills")
      glob(global) { |path| add.call(path, :user) }

      paths.each do |raw|
        path = File.expand_path(raw.to_s.sub(/\A~(?=\/|\z)/, Dir.home))
        if File.directory?(path)
          glob(path) { |p| add.call(p, :path) }
        elsif File.file?(path) && path.end_with?(".md")
          add.call(path, :path)
        else
          warn "Skill path #{path} is not a directory or markdown file (ignored)"
        end
      end

      skills.values.sort_by(&:name)
    end

    # Get a single skill by name through the same scan as .all.
    def self.get(name, cwd: Dir.pwd, paths: [])
      all(cwd: cwd, paths: paths).detect { |s| s.name == name }
    end

    def self.glob(dir, &block)
      return unless File.directory?(dir)

      Dir.glob(File.join(dir, "**", FILENAME)).sort.each(&block)
    end

    def self.realpath(path)
      File.realpath(path)
    rescue SystemCallError
      path
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

    private_class_method :glob, :realpath, :validate, :validate_name,
                         :validate_description, :parse_allowed_tools, :parse_frontmatter
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
      skill = Brute::Skill.load(path)
      skill.name.should == "debugging"
      skill.description.should == "Debug things"
    end
  end

  it "exposes file_path, base_dir, and a location alias" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "debugging", "name: debugging\ndescription: x")
      skill = Brute::Skill.load(path)
      skill.file_path.should == path
      skill.base_dir.should == File.dirname(path)
      skill.location.should == path
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
      skill = Brute::Skill.load(path)
      skill.name.should == "extra"
      skill.respond_to?(:tags).should.be.false
    end
  end

  it "parses optional spec fields" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(
        root, "full",
        "name: full\ndescription: x\nlicense: MIT\ncompatibility: claude\nallowed-tools: read shell\nmetadata:\n  team: core",
      )
      skill = Brute::Skill.load(path)
      skill.license.should == "MIT"
      skill.compatibility.should == "claude"
      skill.allowed_tools.should == %w[read shell]
      skill.metadata.should == { "team" => "core" }
    end
  end

  it "parses disable-model-invocation" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "hidden", "name: hidden\ndescription: x\ndisable-model-invocation: true")
      Brute::Skill.load(path).disable_model_invocation?.should.be.true
    end
  end

  it "defaults disable_model_invocation to false" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "shown", "name: shown\ndescription: x")
      Brute::Skill.load(path).disable_model_invocation?.should.be.false
    end
  end

  it "skips a skill whose description exceeds the length bound" do
    Dir.mktmpdir do |root|
      path = make_skill_dir(root, "long", "name: long\ndescription: #{"x" * 1025}")
      Brute::Skill.load(path).should.be.nil
    end
  end

  it "tags skills with their source" do
    Dir.mktmpdir do |root|
      make_skill_dir(root, "debugging", "name: debugging\ndescription: x")
      Brute::Skill.all(cwd: root).first.source.should == :project
    end
  end

  def with_home(dir)
    old = ENV["HOME"]
    ENV["HOME"] = dir
    yield
  ensure
    ENV["HOME"] = old
  end

  it "project-local skills override same-named global ones" do
    Dir.mktmpdir do |project|
      Dir.mktmpdir do |home|
        make_skill_dir(project, "shared", "name: shared\ndescription: project variant")
        global_dir = File.join(home, ".config", "brute", "skills", "shared")
        FileUtils.mkdir_p(global_dir)
        File.write(File.join(global_dir, "SKILL.md"), "---\nname: shared\ndescription: global variant\n---\n\nBody\n")

        with_home(home) do
          skills = Brute::Skill.all(cwd: project)
          skills.size.should == 1
          skills.first.description.should == "project variant"
          skills.first.source.should == :project
        end
      end
    end
  end

  it "loads skills from explicit paths" do
    Dir.mktmpdir do |root|
      dir = File.join(root, "elsewhere", "custom")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "---\nname: custom\ndescription: explicit\n---\n\nBody\n")

      skills = Brute::Skill.all(cwd: root, paths: [File.join(root, "elsewhere")])
      skills.map(&:name).should == ["custom"]
      skills.first.source.should == :path
    end
  end

  it "expands ~ in explicit paths" do
    Dir.mktmpdir do |home|
      dir = File.join(home, "skills", "homey")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "---\nname: homey\ndescription: x\n---\n\nBody\n")

      with_home(home) do
        skills = Brute::Skill.all(cwd: home, paths: ["~/skills"])
        skills.map(&:name).should.include("homey")
      end
    end
  end

  it "loads the same file only once when reached via a symlink" do
    Dir.mktmpdir do |root|
      make_skill_dir(root, "debugging", "name: debugging\ndescription: x")
      link = File.join(root, ".brute", "skills", "linked")
      File.symlink(File.join(root, ".brute", "skills", "debugging"), link)

      Brute::Skill.all(cwd: root).size.should == 1
    end
  end
end
