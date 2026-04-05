# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "brute"
  spec.version       = "0.1.2"
  spec.authors       = ["Brute Contributors"]
  spec.summary       = "A coding agent built on llm.rb"
  spec.description   = "Production-grade coding agent with tool execution, " \
                        "middleware pipeline, context compaction, session persistence, " \
                        "and multi-provider LLM support."
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "llm.rb", "~> 4.11"
  spec.add_dependency "async", "~> 2.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
