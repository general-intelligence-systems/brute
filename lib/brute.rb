# frozen_string_literal: true

require 'llm'
require 'timeout'
require 'logger'
require 'scampi/kernel_ext'

# Brute — a coding agent built on llm.rb
#
# Cross-cutting concerns are implemented as Rack-style middleware in a
# Middleware::Stack that wraps every LLM call:
#
#   Tracing → Retry → Session → Tokens → Compaction → ToolErrors → DoomLoop → Reasoning → [LLM Call]
#
# Entry point:
#
#   agent = Brute::Agent.new(provider:, model:, tools:, system_prompt:)
#   step  = Brute::Loop::AgentTurn.perform(agent:, session:, pipeline:, input:)
#
require_relative 'brute/version'

module Brute
  def self.provider
    @provider ||= Brute::Providers.guess_from_env
  end

  def self.provider=(p)
    @provider = p
  end
end

require_relative 'brute/diff'
require_relative 'brute/skill'
require_relative 'brute/prompts'
require_relative 'brute/system_prompt'
require_relative 'brute/agent'

# Brute::Store
require_relative 'brute/store/snapshot_store'
require_relative 'brute/store/todo_store'
require_relative 'brute/store/message_store'
require_relative 'brute/store/session'

# Brute::Loop (before Queue — queue tests reference Loop::Step)
require_relative 'brute/loop/agent_stream'
require_relative 'brute/loop/step'
require_relative 'brute/loop/tool_call_step'

# Brute::Queue
require_relative 'brute/queue/file_mutation_queue'
require_relative 'brute/queue/base_queue'
require_relative 'brute/queue/sequential_queue'
require_relative 'brute/queue/parallel_queue'

# Brute::Loop (agent_turn depends on Queue)
require_relative 'brute/loop/agent_turn'

require_relative 'brute/patches/anthropic_tool_role'
require_relative 'brute/patches/buffer_nil_guard'

require_relative 'brute/middleware'
require_relative 'brute/tools'
require_relative 'brute/providers'
