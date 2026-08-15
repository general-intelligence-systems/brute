# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # SkillsXml — per-iteration middleware (just outside PromptTemplate).
    # SCAFFOLD: pass-through no-op (FEATURES.md M16).
    #
    # Ports prime-agent `packages/coding-agent/src/core/skills.ts`: skill
    # discovery + the prompt block. SKILL.md roots (frontmatter name +
    # description REQUIRED — a missing description silently drops the skill;
    # disable-model-invocation honored); directories: user
    # ~/.prime/agent/skills, project .prime/agent/skills, explicit paths;
    # kernel-backed skill detection (upstream: pyproject.toml +
    # src/<import>/__init__.py; here: a lib/ dir the kernel bootstrap globs
    # onto the load path); prompt block <available_skills> with
    # <name>/<type>/<python_import>/<description>/<location>; /skill:<name>
    # expands a <skill name location> block.
    #
    # Fill-in: extends Brute::Prompts::Skills (already wired into
    # prompts/system.erb) with the type/import fields and the skill-command
    # expansion; dedupe by realpath, name collisions warn.
    class SkillsXml
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end

__END__

describe "prime_agent/middleware/skills_xml" do
  it "passes env through to the inner app (scaffold)" do
    app = ->(env) { env[:inner] = true; env }
    env = {}
    PrimeAgent::Middleware::SkillsXml.new(app).call(env)
    env[:inner].should.be.true
  end
end
