# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Prompts
    # The <available_skills> system-prompt section.
    #
    # Uses skill objects from ctx[:skills] when present (handed in via
    # Brute::Middleware::Skills -> env[:metadata][:skills]); falls back to
    # scanning from ctx[:cwd] so the default stacks keep working unwired.
    # Skills with disable_model_invocation? are loaded but hidden here.
    # Returns nil when no skills are visible, dropping the section entirely.
    module Skills
      def self.call(ctx)
        skills = ctx[:skills] || Brute::Skill.all(cwd: ctx[:cwd] || Dir.pwd)
        visible = skills.reject(&:disable_model_invocation?)
        return nil if visible.empty?

        Prompts.render("skills", ctx.merge(skills: visible))
      end
    end
  end
end

__END__

describe "brute/prompts/skills" do
  require "tmpdir"

  def skill(name, description: "Does things", file_path: "/x/#{name}/SKILL.md", hidden: false)
    Brute::Skill.new(
      name: name, description: description, file_path: file_path,
      disable_model_invocation: hidden,
    )
  end

  it "returns nil when no skills are found" do
    Dir.mktmpdir do |dir|
      Brute::Prompts::Skills.call(cwd: dir).should.be.nil
    end
  end

  it "renders skill objects passed through ctx" do
    out = Brute::Prompts::Skills.call(skills: [skill("debugging", description: "Debug things")])
    out.should.include("<name>debugging</name>")
    out.should.include("<description>Debug things</description>")
    out.should.include("<location>/x/debugging/SKILL.md</location>")
  end

  it "prefers ctx[:skills] over scanning, even when empty" do
    Dir.mktmpdir do |dir|
      skill_dir = File.join(dir, ".brute", "skills", "debugging")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: debugging\ndescription: x\n---\n\nBody\n")

      Brute::Prompts::Skills.call(cwd: dir, skills: []).should.be.nil
      Brute::Prompts::Skills.call(cwd: dir).should.include("debugging")
    end
  end

  it "hides disable-model-invocation skills from the listing" do
    out = Brute::Prompts::Skills.call(skills: [skill("shown"), skill("hidden", hidden: true)])
    out.should.include("shown")
    out.should.not.include("hidden")
  end

  it "returns nil when every skill is hidden" do
    Brute::Prompts::Skills.call(skills: [skill("hidden", hidden: true)]).should.be.nil
  end

  it "xml-escapes skill fields" do
    out = Brute::Prompts::Skills.call(skills: [skill("debugging", description: %q{a<b>&"c'})])
    out.should.include("a&lt;b&gt;&amp;&quot;c&apos;")
  end
end
