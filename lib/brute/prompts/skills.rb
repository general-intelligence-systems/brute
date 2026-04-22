# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  require "tmpdir"

  it "returns nil when no skills are found" do
    Dir.mktmpdir do |dir|
      Brute::Prompts::Skills.call(cwd: dir).should.be.nil
    end
  end
end
