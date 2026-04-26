# frozen_string_literal: true

require 'ruby_llm'
require 'timeout'
require 'logger'
require 'scampi/kernel_ext'
require 'colorize_extended'

# Brute — a coding agent built on ruby_llm
#
# Cross-cutting concerns are implemented as Rack-style middleware in a
# Pipeline that wraps every LLM call:
#
#   Tracing → Retry → Session → Tokens → Compaction → ToolErrors → DoomLoop → Reasoning → [LLM Call]
#
# Entry point:
#
#   agent = Brute::Agent.new(provider:, model:, tools:, system_prompt:)
#   step  = Brute::Loop::AgentTurn.perform(agent:, session:, pipeline:, input:)
#
require 'brute/version'

module Brute
  LOGO = <<-LOGO
 .o8                                .             
"888                              .o8             
 888oooo.  oooo d8b oooo  oooo  .o888oo  .ooooo.  
 d88' `88b `888""8P `888  `888    888   d88' `88b 
 888   888  888      888   888    888   888ooo888 
 888   888  888      888   888    888 . 888    .o 
 `Y8bod8P' d888b     `V88V"V8P'   "888" `Y8bod8P' 
  LOGO

  def self.provider
    @provider ||= Brute::Providers.guess_from_env
  end

  def self.provider=(p)
    @provider = p
  end
end

Dir.glob("#{__dir__}/brute/**/*.rb").sort.each do |path|
  require path
end
