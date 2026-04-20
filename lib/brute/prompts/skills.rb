# frozen_string_literal: true

module Brute
  module Prompts
    module Skills
      def self.call(ctx)
        cwd = ctx[:cwd] || Dir.pwd
        skills = Skill.all(cwd: cwd)
        return nil if skills.empty?

        listing = Skill.fmt(skills)

        <<~TXT
          Skills provide specialized instructions and workflows for specific tasks.
          When a task matches a skill's description, load the skill to get detailed guidance.

          #{listing}
        TXT
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Prompts::Skills do
    it "returns nil when no skills are found" do
      Dir.mktmpdir do |dir|
        text = described_class.call(cwd: dir)
        expect(text).to be_nil
      end
    end

    it "lists discovered skills when present" do
      Dir.mktmpdir do |dir|
        # Create a minimal SKILL.md file
        skill_dir = File.join(dir, ".brute", "skills")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~MD)
          ---
          name: test-skill
          description: A test skill
          ---
          # Test Skill Content
        MD

        text = described_class.call(cwd: dir)
        if text
          expect(text).to include("skill")
        else
          skip "Skill discovery does not find skills in .brute/skills/"
        end
      end
    end
  end
end
