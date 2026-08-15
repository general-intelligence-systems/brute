# frozen_string_literal: true

require "yaml"
require "cgi"

# SkillsCatalog — picoclaw's skill discovery + prompt catalog (pkg/skills/
# loader.go, validation.go; prompt injection pkg/agent/context.go:278-306).
#
# Roots in priority order: <workspace>/skills > ~/.picoclaw/skills >
# .brute/skills (the port's builtin root); first occurrence of a name wins.
# A skill is a direct subdirectory containing SKILL.md; metadata comes from
# YAML frontmatter (name/description), falling back to the first H1 + first
# paragraph. Names must be alphanumeric-with-hyphens, <=64 chars; a
# description is required (<=1024 chars).
#
# Contributes env[:metadata][:skills_part]: the "# Skills" section with the
# <skills> XML catalog (bodies NOT inlined — "To use a skill, read its
# SKILL.md file using the read_file tool"), plus "# Active Skills" full
# bodies (frontmatter stripped) for skills named in the workspace AGENT.md/
# AGENTS.md frontmatter `skills:` list.
class SkillsCatalog
  MAX_NAME_LENGTH = 64
  MAX_DESCRIPTION_LENGTH = 1024
  NAME_PATTERN = /\A[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*\z/

  Skill = Struct.new(:name, :description, :path, :source, :body)

  def initialize(app, workspace: Dir.pwd,
                 roots: [File.join(Dir.pwd, "skills"),
                         File.expand_path("~/.picoclaw/skills"),
                         File.join(Dir.pwd, ".brute", "skills")],
                 agent_files: %w[AGENT.md AGENTS.md])
    @app = app
    @workspace = workspace
    @roots = roots
    @agent_files = agent_files.map { |f| File.join(workspace, f) }
  end

  def call(env)
    env[:metadata][:skills_part] = prompt_part
    @app.call(env)
  end

  def prompt_part
    skills = discover
    return "" if skills.empty?

    parts = []
    catalog = build_catalog(skills)
    parts << "# Skills\n\nThe following skills extend your capabilities. To use a skill, read its SKILL.md file using the read_file tool.\n\n#{catalog}"

    active = active_bodies(skills)
    parts << active unless active.empty?
    parts.join("\n\n")
  end

  # Loader port: first occurrence of a name wins across prioritized roots.
  def discover
    seen = {}
    skills = []
    labels = %w[workspace global builtin]
    @roots.each_with_index do |root, i|
      next unless File.directory?(root)

      Dir.children(root).sort.each do |entry|
        dir = File.join(root, entry)
        skill_md = File.join(dir, "SKILL.md")
        next unless File.file?(skill_md)

        skill = load_skill(skill_md, dir, labels[i] || "builtin")
        next if skill.nil? || seen.key?(skill.name)

        seen[skill.name] = true
        skills << skill
      end
    end
    skills
  end

  private

  def load_skill(path, dir, source)
    raw = File.read(path)
    frontmatter, body = parse_frontmatter(raw)

    name = frontmatter["name"].to_s.strip
    description = frontmatter["description"].to_s.strip

    if name.empty? || description.empty?
      h1 = body[/^#\s+(.+)/, 1].to_s.strip
      paragraph = body.gsub(/^#.*$/, "").strip.split(/\n\s*\n/).first.to_s.strip
      name = h1 if name.empty?
      description = paragraph if description.empty?
    end

    return nil unless valid_name?(name)
    return nil if description.empty? || description.length > MAX_DESCRIPTION_LENGTH

    Skill.new(name, description, dir, source, body.strip)
  rescue SystemCallError, Psych::Exception
    nil
  end

  def valid_name?(name)
    return false if name.empty?
    return false if name.start_with?("/", "~") # must not be an absolute path
    return false if name.length > MAX_NAME_LENGTH

    NAME_PATTERN.match?(name) ? true : false
  end

  def parse_frontmatter(raw)
    return [{}, raw] unless raw.start_with?("---\n")

    closing = raw.index("\n---", 4)
    return [{}, raw] unless closing

    frontmatter = YAML.safe_load(raw[4...closing]) || {}
    body = raw[(closing + 4)..].to_s.sub(/\A---\s*\n?/, "")
    [frontmatter.is_a?(Hash) ? frontmatter : {}, body]
  rescue Psych::Exception
    [{}, raw]
  end

  def xml_escape(text)
    CGI.escapeHTML(text.to_s)
  end

  def build_catalog(skills)
    lines = ["<skills>"]
    skills.each do |skill|
      lines << "  <skill>"
      lines << "    <name>#{xml_escape(skill.name)}</name>"
      lines << "    <description>#{xml_escape(skill.description)}</description>"
      lines << "    <location>#{xml_escape(skill.path)}</location>"
      lines << "    <source>#{xml_escape(skill.source)}</source>"
      lines << "  </skill>"
    end
    lines << "</skills>"
    lines.join("\n")
  end

  # AGENT.md/AGENTS.md frontmatter `skills:` (upstream: AGENT.md frontmatter
  # skills list + /use-forced skills — the port has no /use surface).
  def active_skill_names
    @agent_files.each do |path|
      next unless File.file?(path)

      frontmatter, = parse_frontmatter(File.read(path))
      skills = frontmatter["skills"]
      return skills.map { |s| s.to_s.downcase.strip } if skills.is_a?(Array)
    end
    nil
  end

  def active_bodies(skills)
    names = active_skill_names
    return "" if names.nil? || names.empty?

    bodies = skills.select { |s| names.include?(s.name.downcase) }
                   .map { |s| "### Skill: #{s.name}\n\n#{s.body}" }
    return "" if bodies.empty?

    "# Active Skills\n\n#{bodies.join("\n\n---\n\n")}"
  end
end
