# frozen_string_literal: true

require "pathname"
require "fileutils"

require "bundler/setup"
require "brute"
require "brute/tools"

module Brute
  module Tools
    # The `skill` tool — stages 2 (activation) and 3 (execution) of the Agent
    # Skills progressive-disclosure lifecycle (https://agentskills.io).
    #
    # Stage 1 (discovery) happens in the system prompt: Brute::Prompts::Skills
    # lists each skill's name + description only (~100 tokens each). When a task
    # matches, the model calls this tool with the skill name to pull the full
    # SKILL.md body into the conversation (stage 2).
    #
    # The output also reports the skill's base directory and a capped listing of
    # bundled files. That is stage 3: skills bundle scripts/, references/, and
    # assets/ that the model runs or reads *through the agent's existing tools*
    # (`shell`, `read`) by relative path. There is no separate skill runtime.
    #
    # The tool must scan the same directories as Prompts::Skills, or it would
    # advertise skills it cannot load. Both default to Dir.pwd; agents that point
    # the prompt at a custom root (e.g. ctx.merge(cwd: __dir__)) should build the
    # tool with the matching cwd: Brute::Tools::SkillLoad.new(cwd: __dir__).
    #
    # Reference: opencode's tool/skill.ts.
    class SkillLoad < Brute::Tool
      description "Load a specialized skill when the task at hand matches one of the " \
                  "available skills listed in the system context. This injects the skill's " \
                  "full instructions into the conversation, plus the skill's base directory " \
                  "and a listing of bundled files (scripts, references, assets) that you can " \
                  "run or read by relative path using your existing tools. The name must match " \
                  "one of the available skills."

      param :name, type: "string", desc: "The name of the skill from the available skills list", required: true

      FILE_LIMIT = 10

      def name; "skill"; end

      def initialize(cwd: Dir.pwd)
        super()
        @cwd = cwd
      end

      def execute(name:)
        skill = Brute::Skill.get(name, cwd: @cwd)
        return unknown_skill(name) unless skill

        directory = File.dirname(skill.location)
        files = bundled_files(directory)

        render(skill, directory, files)
      end

      private

      def unknown_skill(name)
        available = Brute::Skill.all(cwd: @cwd).map(&:name)
        listing = available.empty? ? "(none)" : available.join(", ")
        "Error: unknown skill #{name.inspect}. Available skills: #{listing}"
      end

      def bundled_files(directory)
        Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH)
           .select { |p| File.file?(p) }
           .reject { |p| File.basename(p) == Brute::Skill::FILENAME }
           .map { |p| Pathname.new(p).relative_path_from(Pathname.new(directory)).to_s }
           .sort
           .first(FILE_LIMIT)
      end

      def render(skill, directory, files)
        lines = [
          "<skill name=\"#{skill.name}\">",
          "# Skill: #{skill.name}",
          "",
          skill.content,
          "",
          "Base directory for this skill: #{directory}",
          "Relative paths in this skill (e.g. scripts/, references/, assets/) are relative to " \
            "this base directory. Use your existing tools (read, shell) to access them.",
        ]

        unless files.empty?
          lines << ""
          lines << "Bundled files (sampled, up to #{FILE_LIMIT}):"
          files.each { |f| lines << "  #{f}" }
        end

        lines << "</skill>"
        lines.join("\n")
      end
    end
  end
end

__END__

describe "brute/tools/skill_load" do
  require "tmpdir"

  def write_skill(root, name, body: "Do the thing.", frontmatter: nil)
    dir = File.join(root, ".brute", "skills", name)
    FileUtils.mkdir_p(dir)
    frontmatter ||= "name: #{name}\ndescription: A skill that does #{name}"
    File.write(File.join(dir, "SKILL.md"), "---\n#{frontmatter}\n---\n\n#{body}\n")
    dir
  end

  it "returns the skill body and base directory" do
    Dir.mktmpdir do |root|
      dir = write_skill(root, "debugging", body: "Step 1. Reproduce.")
      out = Brute::Tools::SkillLoad.new(cwd: root).call(name: "debugging")
      out.should =~ /Step 1\. Reproduce\./
      out.should =~ /Base directory for this skill: #{Regexp.escape(dir)}/
    end
  end

  it "lists bundled files but not SKILL.md itself" do
    Dir.mktmpdir do |root|
      dir = write_skill(root, "deploy")
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      File.write(File.join(dir, "scripts", "run.sh"), "echo hi")
      out = Brute::Tools::SkillLoad.new(cwd: root).call(name: "deploy")
      out.should =~ %r{scripts/run\.sh}
      out.should.not =~ /SKILL\.md/
    end
  end

  it "caps bundled files at FILE_LIMIT" do
    Dir.mktmpdir do |root|
      dir = write_skill(root, "many")
      15.times { |i| File.write(File.join(dir, "f#{i}.txt"), "x") }
      out = Brute::Tools::SkillLoad.new(cwd: root).call(name: "many")
      out.scan(/^  f\d+\.txt$/).size.should.be <= Brute::Tools::SkillLoad::FILE_LIMIT
    end
  end

  it "returns a tool-error string (not an exception) for an unknown skill" do
    Dir.mktmpdir do |root|
      write_skill(root, "alpha")
      out = Brute::Tools::SkillLoad.new(cwd: root).call(name: "missing")
      out.should =~ /unknown skill/
      out.should =~ /alpha/
    end
  end

  it "defaults cwd to Dir.pwd" do
    Brute::Tools::SkillLoad.new.should.be.kind_of(Brute::Tools::SkillLoad)
  end
end
