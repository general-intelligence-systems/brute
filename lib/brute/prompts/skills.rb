# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Prompts
    module Skills
      def self.call(ctx)
        cwd = ctx[:cwd] || Dir.pwd
        skills = Brute::Skill.all(cwd: cwd)
        return nil if skills.empty?

        listing = Brute::Skill.fmt(skills)

        <<~TXT
          Skills provide specialized instructions and workflows for specific tasks.
          Use the skill tool to load a skill when a task matches its description. The tool
          returns the skill's full instructions plus a base directory whose bundled files
          (scripts, references, assets) you can read or run by relative path.

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
