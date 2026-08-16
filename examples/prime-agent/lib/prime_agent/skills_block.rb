# frozen_string_literal: true

require "brute"

module PrimeAgent
  # SkillsBlock — the <available_skills> prompt section. The port of
  # prime-agent's formatSkillsForPrompt (core/skills.ts:450-481): the header
  # lines and per-skill <name>/<type>/<import>/<description>/<location>
  # fields, XML-escaped; skills with disable-model-invocation are hidden and
  # an empty listing drops the section.
  #
  # Type/import adaptation: upstream's "python" skills carry a python_import
  # prepared in the IPython kernel; this port's kernel-backed skills carry a
  # lib/ directory of Ruby files that the bootstrap puts on the kernel load
  # path, so the field is <ruby_import> and the header tells the model to
  # `require` it.
  module SkillsBlock
    module_function

    def call(cwd: Dir.pwd)
      skills = Brute::Skill.all(cwd: cwd).reject(&:disable_model_invocation?)
      return nil if skills.empty?

      lines = [
        "The following skills provide specialized instructions for specific tasks.",
        "Use iruby to inspect a skill's file when the task matches its description.",
        "Skills with a ruby_import are on the IRuby kernel load path and can be required by that name.",
        "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
        "",
        "<available_skills>",
      ]

      skills.each do |skill|
        import = ruby_import(skill)
        lines << "  <skill>"
        lines << "    <name>#{escape_xml(skill.name)}</name>"
        lines << "    <type>#{import ? "ruby" : "markdown"}</type>"
        lines << "    <ruby_import>#{escape_xml(import)}</ruby_import>" if import
        lines << "    <description>#{escape_xml(skill.description)}</description>"
        lines << "    <location>#{escape_xml(skill.file_path)}</location>"
        lines << "  </skill>"
      end

      lines << "</available_skills>"
      lines.join("\n")
    end

    # A skill is kernel-backed ("ruby") when its directory ships lib/*.rb;
    # the import name is the first such file's basename (skill name with
    # hyphens translated, matching the edit skill's convention).
    def ruby_import(skill)
      dir = File.dirname(skill.file_path.to_s)
      libs = Dir.glob(File.join(dir, "lib", "*.rb")).sort
      return nil if libs.empty?

      File.basename(libs.first, ".rb")
    end

    def escape_xml(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
           .gsub('"', "&quot;").gsub("'", "&apos;")
    end
  end
end

__END__

describe "prime_agent/skills_block" do
  require "fileutils"
  require "tmpdir"

  def write_skill(root, name, with_lib: false, hidden: false)
    dir = File.join(root, ".brute", "skills", name)
    FileUtils.mkdir_p(dir)
    frontmatter = ["---", "name: #{name}", "description: Does #{name}"]
    frontmatter << "disable-model-invocation: true" if hidden
    File.write(File.join(dir, "SKILL.md"), "#{frontmatter.join("\n")}\n---\n\nBody\n")
    if with_lib
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "#{name.tr("-", "_")}.rb"), "# lib\n")
    end
    dir
  end

  it "renders the upstream block shape with type and ruby_import fields" do
    Dir.mktmpdir do |dir|
      write_skill(dir, "plain")
      write_skill(dir, "kernel-backed", with_lib: true)
      out = PrimeAgent::SkillsBlock.call(cwd: dir)
      out.should.include "<available_skills>"
      out.should.include "Use iruby to inspect a skill's file"
      out.should.include "<type>markdown</type>"
      out.should.include "<type>ruby</type>"
      out.should.include "<ruby_import>kernel_backed</ruby_import>"
      out.should.include "<name>plain</name>"
      out.should.include "<location>#{File.join(dir, ".brute", "skills", "plain", "SKILL.md")}</location>"
    end
  end

  it "returns nil with no skills and hides disable-model-invocation skills" do
    Dir.mktmpdir do |dir|
      PrimeAgent::SkillsBlock.call(cwd: dir).should.be.nil
      write_skill(dir, "hidden", hidden: true)
      PrimeAgent::SkillsBlock.call(cwd: dir).should.be.nil
    end
  end
end
