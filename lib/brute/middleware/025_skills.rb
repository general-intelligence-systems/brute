# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Loads skill objects into the agent context.
    #
    # Skills are handed in as objects — discovery is the caller's job:
    #
    #   skills = Brute::Skill.all(cwd: Dir.pwd)
    #   agent
    #     .use(Brute::Middleware::Skills, skills: skills)
    #     .use(Brute::Middleware::SystemPrompt)
    #
    # Per turn:
    #   1. env[:skills] = the objects, for downstream middleware, tools, and
    #      the terminal app (prime-agent's resourceLoader.getSkills() analogue)
    #   2. env[:metadata][:skills] = the same objects, so
    #      Middleware::SystemPrompt merges them into the prompt ctx and
    #      Brute::Prompts::Skills renders the <available_skills> section
    #
    # Place it before Middleware::SystemPrompt in the stack. It never touches
    # env[:messages] itself.
    class Skills
      def initialize(app, skills: [])
        @app = app
        @skills = skills
      end

      def call(env)
        env[:skills] = @skills
        env[:metadata] ||= {}
        env[:metadata][:skills] ||= @skills

        @app.call(env)
      end
    end
  end
end

__END__

describe "brute/middleware/025_skills" do
  def skill(name)
    Brute::Skill.new(name: name, description: "x", file_path: "/x/#{name}/SKILL.md")
  end

  def build_middleware(skills: [], &inner)
    Brute::Middleware::Skills.new(inner || ->(env) { env }, skills: skills)
  end

  it "stashes skill objects in env[:skills]" do
    skills = [skill("debugging")]
    env = { messages: Brute.log, metadata: {} }

    build_middleware(skills: skills).call(env)

    env[:skills].should == skills
  end

  it "mirrors skills into env[:metadata] for the prompt layer" do
    skills = [skill("debugging")]
    env = { messages: Brute.log }

    build_middleware(skills: skills).call(env)

    env[:metadata][:skills].should == skills
  end

  it "does not clobber an explicit metadata[:skills]" do
    explicit = [skill("explicit")]
    env = { messages: Brute.log, metadata: { skills: explicit } }

    build_middleware(skills: [skill("other")]).call(env)

    env[:metadata][:skills].should == explicit
    env[:skills].map(&:name).should == ["other"]
  end

  it "defaults to an empty list and passes control down the chain" do
    called = false
    env = { messages: Brute.log }

    build_middleware { |e| called = true }.call(env)

    env[:skills].should == []
    called.should.be.true
  end
end
