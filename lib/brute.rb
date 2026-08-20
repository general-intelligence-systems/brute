# frozen_string_literal: true

require "bundler/setup"

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

  # NOTE: Brute owns no LLM configuration and no LLM library. All
  # provider/model/credential config lives in the pipeline's terminal `run`
  # proc, which the user writes with whatever LLM library they prefer
  # (ruby_llm, llm.rb, openai, anthropic, raw HTTP, ...). The proc converts
  # env[:messages] (Brute::Message values — see Brute.log) to the library's
  # format, makes the call, and appends the response back as Brute::Message
  # values — the MessageTransport pattern. See examples/ruby_llm.rb,
  # examples/llm.rb, examples/openai.rb and examples/anthropic.rb.

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

  # Load an agent from a brute.ru file — the Brute analogue of `rackup`.
  # The file is a rackup-style script using the same `use` / `run` / `map`
  # DSL as `Brute.agent`, and what comes back is the AgentPipeline itself,
  # so it can be started, further `.use`d, or served through
  # Brute::Rack::Adapter:
  #
  #   Brute.load_agent.start("what changed?")               # ./agent.ru
  #   Brute.load_agent("examples/agents/brute.ru").start("hi")
  #
  def self.load_agent(path = "agent.ru")
    path = File.expand_path(path)
    raise ArgumentError, "no such agent file: #{path}" unless File.file?(path)

    Brute::Turn::AgentPipeline.parse_file(path)
  end

  # Adapt any Brute tools (hashes, Brute::Tool, Brute::Turn::ToolPipeline,
  # SubAgent …) into a { name_sym => Brute::Tools::Adapter } hash. Each
  # adapter exposes #to_h — a neutral JSON-Schema-ish definition the inline
  # `run` proc converts to whatever its LLM library expects.
  def self.tools(tools)
    Brute::Tools::Adapter.wrap_all(tools || [])
  end


  def self.provider=(p)
    @provider = p.to_sym
  end
end

Dir.glob("#{__dir__}/brute/**/*.rb").sort.each do |path|
  require path
end

# gangsta g-dogg bruh...
