# frozen_string_literal: true

require "bundler/setup"

require "ruby_llm"
require "rack"
require 'timeout'
require 'logger'
require 'colorize_extended'
require 'active_support/all'

require_relative 'brute/version'

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

  # NOTE: Brute owns no LLM configuration. Calling an LLM is just
  # `RubyLLM.chat.ask "..."`, and all provider/model/credential config lives
  # in the pipeline's terminal `run` proc — typically via `RubyLLM.context`:
  #
  #   run ->(env) do
  #     context = RubyLLM.context { |c| c.ollama_api_base = ENV["OLLAMA_API_BASE"] }
  #     ...
  #   end
  #
  # See examples/agents/01_basic_agent.rb.

  def self.provider
    @provider ||= :anthropic
  end

  # Start building an agent turn. Returns an AgentPipeline — a rack-style
  # builder that is also the runnable Agent: chain `.use` for middleware and
  # `.run` for the terminal LLM-call proc (both return the AgentPipeline), then
  # invoke it with `#start`. It takes no config — LLM config lives in the `run`
  # proc, tools go to the ToolPipeline middleware, the log to SessionLog.
  #
  #   agent = Brute.agent
  #     .use(Brute::Middleware::SystemPrompt)
  #     .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  #     .run ->(env) { ... }      # the LLM-call proc (provider/model/creds here)
  #
  #   agent.start("what changed?")
  #
  # A block form is equivalent (evaluated in the AgentPipeline's context):
  #
  #   Brute.agent do
  #     use Brute::Middleware::SystemPrompt
  #     run ->(env) { ... }
  #   end
  def self.agent(&block)
    Brute::Turn::AgentPipeline.new(&block)
  end

  # Adapt any Brute tools (hashes, Brute::Turn::ToolPipeline, SubAgent, RubyLLM::Tool …)
  # into a { name_sym => RubyLLM::Tool } hash — the shape an inline `run`
  # proc hands to RubyLLM.chat.with_tools or a provider #complete call.
  def self.rubyllm_tools(tools)
    Brute::Tools::Adapter.wrap_all(tools || []).transform_values(&:to_ruby_llm)
  end
  
  def self.provider=(p)
    @provider = p.to_sym
  end
end

Dir.glob("#{__dir__}/{brute,ruby_llm}/**/*.rb").sort.each do |path|
  require path
end

# gangsta g-dogg bruh...
