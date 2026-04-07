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
