# frozen_string_literal: true

require_relative 'lib/brute/version'

Gem::Specification.new do |spec|
  spec.name          = 'brute'
  spec.version       = Brute::VERSION
  spec.authors       = ['Brute Contributors']
  spec.summary       = 'A coding agent built on ruby_llm'
  spec.description   = 'Production-grade coding agent with tool execution, ' \
                        'middleware pipeline, context compaction, session persistence, ' \
                        'and multi-provider LLM support.'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/general-intelligence-systems/brute'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata = {
    "documentation_uri" => "https://general-intelligence-systems.github.io/brute/",
  }

  spec.files         = Dir['lib/**/*.rb', 'lib/**/*.txt']
  spec.require_paths = ['lib']

  spec.add_dependency 'async', '~> 2.0'
  spec.add_dependency 'diff-lcs', '>= 1.5'
  spec.add_dependency 'ruby_llm'
  spec.add_dependency 'scampi'
  spec.add_dependency 'activesupport'
  spec.add_dependency 'colorize-extended'
  spec.add_dependency 'rack', "~> 3.0"
  spec.add_dependency "net-http-persistent"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "google-protobuf", "~> 4.34"

  spec.add_development_dependency 'rake', '~> 13.0'
end
