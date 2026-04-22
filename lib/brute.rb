# frozen_string_literal: true

require 'llm'
require 'timeout'
require 'logger'
require 'scampi/kernel_ext'

# Brute — a coding agent built on llm.rb
#
# Cross-cutting concerns are implemented as Rack-style middleware in a
# Pipeline that wraps every LLM call:
#
#   Tracing → Retry → Session → Tokens → Compaction → ToolErrors → DoomLoop → Reasoning → [LLM Call]
#
require_relative 'brute/version'

module Brute
  module Hooks; end

  def self.provider
    @provider ||= Brute::Providers.guess_from_env
  end

  def self.provider=(p)
    @provider = p
  end

  def self.agent(
    provider: self.provider,
    cwd: Dir.pwd,
    model: nil,
    tools: Tools::ALL,
    session: nil,
    reasoning: {},
    agent_name: nil,
    **callbacks
  )

    Orchestrator.new(
      provider: provider,
      model: model,
      tools: tools,
      cwd: cwd,
      session: session,
      reasoning: reasoning,
      agent_name: agent_name,
      **callbacks
    )
  end
end

# Infrastructure
require_relative 'brute/diff'
require_relative 'brute/snapshot_store'
require_relative 'brute/todo_store'
require_relative 'brute/file_mutation_queue'
require_relative 'brute/doom_loop'
require_relative 'brute/hooks'
require_relative 'brute/compactor'
require_relative 'brute/skill'
require_relative 'brute/prompts'
require_relative 'brute/system_prompt'
require_relative 'brute/message_store'
require_relative 'brute/session'
require_relative 'brute/pipeline'
require_relative 'brute/agent_stream'

require_relative 'brute/patches/anthropic_tool_role'
require_relative 'brute/patches/buffer_nil_guard'

require_relative 'brute/middleware'
require_relative 'brute/tools'
require_relative 'brute/providers'
require_relative 'brute/orchestrator'
