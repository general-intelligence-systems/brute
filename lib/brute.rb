# frozen_string_literal: true

require 'llm'
require 'timeout'
require 'logger'

# Brute — a coding agent built on llm.rb
#
# Cross-cutting concerns are implemented as Rack-style middleware in a
# Pipeline that wraps every LLM call:
#
#   Tracing → Retry → Session → Tokens → Compaction → ToolErrors → DoomLoop → Reasoning → [LLM Call]
#
require_relative 'brute/version'

module Brute
  module Tools; end
  module Hooks; end
  module Middleware; end
end

# Infrastructure
require_relative 'brute/diff'
require_relative 'brute/snapshot_store'
require_relative 'brute/todo_store'
require_relative 'brute/file_mutation_queue'
require_relative 'brute/doom_loop'
require_relative 'brute/hooks'
require_relative 'brute/compactor'
require_relative 'brute/prompts/base'
require_relative 'brute/prompts/identity'
require_relative 'brute/prompts/tone_and_style'
require_relative 'brute/prompts/objectivity'
require_relative 'brute/prompts/task_management'
require_relative 'brute/prompts/doing_tasks'
require_relative 'brute/prompts/tool_usage'
require_relative 'brute/prompts/conventions'
require_relative 'brute/prompts/git_safety'
require_relative 'brute/prompts/code_references'
require_relative 'brute/prompts/environment'
require_relative 'brute/prompts/instructions'
require_relative 'brute/prompts/editing_approach'
require_relative 'brute/prompts/autonomy'
require_relative 'brute/prompts/editing_constraints'
require_relative 'brute/prompts/frontend_tasks'
require_relative 'brute/prompts/proactiveness'
require_relative 'brute/prompts/code_style'
require_relative 'brute/prompts/security_and_safety'
require_relative 'brute/prompts/skills'
require_relative 'brute/prompts/plan_reminder'
require_relative 'brute/prompts/max_steps'
require_relative 'brute/prompts/build_switch'
require_relative 'brute/skill'
require_relative 'brute/system_prompt'
require_relative 'brute/message_store'
require_relative 'brute/session'
require_relative 'brute/pipeline'
require_relative 'brute/agent_stream'

# Provider patches
require_relative 'brute/patches/anthropic_tool_role'
require_relative 'brute/patches/buffer_nil_guard'

# Middleware (Rack-style)
require_relative 'brute/middleware/base'
require_relative 'brute/middleware/llm_call'
require_relative 'brute/middleware/retry'
require_relative 'brute/middleware/doom_loop_detection'
require_relative 'brute/middleware/token_tracking'
require_relative 'brute/middleware/compaction_check'
require_relative 'brute/middleware/session_persistence'
require_relative 'brute/middleware/message_tracking'
require_relative 'brute/middleware/tracing'
require_relative 'brute/middleware/tool_error_tracking'
require_relative 'brute/middleware/reasoning_normalizer'
require_relative "brute/middleware/tool_use_guard"
require_relative "brute/middleware/otel"

# Tools
require_relative 'brute/tools/fs_read'
require_relative 'brute/tools/fs_write'
require_relative 'brute/tools/fs_patch'
require_relative 'brute/tools/fs_remove'
require_relative 'brute/tools/fs_search'
require_relative 'brute/tools/fs_undo'
require_relative 'brute/tools/shell'
require_relative 'brute/tools/net_fetch'
require_relative 'brute/tools/todo_write'
require_relative 'brute/tools/todo_read'
require_relative 'brute/tools/delegate'
require_relative 'brute/tools/question'

# Orchestrator (depends on tools, middleware, and infrastructure)
require_relative 'brute/orchestrator'

module Brute
  # The complete set of tools available to the agent.
  TOOLS = [
    Tools::FSRead,
    Tools::FSWrite,
    Tools::FSPatch,
    Tools::FSRemove,
    Tools::FSSearch,
    Tools::FSUndo,
    Tools::Shell,
    Tools::NetFetch,
    Tools::TodoWrite,
    Tools::TodoRead,
    Tools::Delegate,
    Tools::Question
  ].freeze

  # Default provider, resolved from environment.
  def self.provider
    @provider ||= resolve_provider
  end

  def self.provider=(p)
    @provider = p
  end

  # Create a new orchestrator with sensible defaults.
  def self.agent(cwd: Dir.pwd, model: nil, tools: TOOLS, session: nil, reasoning: {}, agent_name: nil, **callbacks)
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

  PROVIDERS = {
    'anthropic' => ->(key) { LLM.anthropic(key: key).tap { Patches::AnthropicToolRole.apply! } },
    'openai' => ->(key) { LLM.openai(key: key) },
    'google' => ->(key) { LLM.google(key: key) },
    'deepseek' => ->(key) { LLM.deepseek(key: key) },
    'ollama' => ->(key) { LLM.ollama(key: key) },
    'xai' => ->(key) { LLM.xai(key: key) }
  }.freeze

  # List provider names that have API keys configured in the environment.
  def self.configured_providers
    PROVIDERS.keys.select { |name| api_key_for(name) }
  end

  # Build a provider instance for the given name using available API keys.
  # Returns nil if no key is found.
  def self.provider_for(name)
    key = api_key_for(name)
    return nil unless key

    factory = PROVIDERS[name]
    return nil unless factory

    factory.call(key)
  end

  # Look up the API key for a given provider name.
  def self.api_key_for(name)
    # Explicit generic key always works
    return ENV["LLM_API_KEY"] if ENV["LLM_API_KEY"]

    case name
    when "anthropic" then ENV["ANTHROPIC_API_KEY"]
    when "openai"    then ENV["OPENAI_API_KEY"]
    when "google"    then ENV["GOOGLE_API_KEY"]
    end
  end

  # Resolve the LLM provider from environment variables.
  #
  # Checks in order:
  #   1. LLM_API_KEY + LLM_PROVIDER (explicit)
  #   2. ANTHROPIC_API_KEY (implicit: provider = anthropic)
  #   3. OPENAI_API_KEY   (implicit: provider = openai)
  #   4. GOOGLE_API_KEY   (implicit: provider = google)
  #
  # Returns nil if no key is found. Error is deferred to Orchestrator#run.
  def self.resolve_provider
    if ENV['LLM_API_KEY']
      key = ENV['LLM_API_KEY']
      name = ENV.fetch('LLM_PROVIDER', 'anthropic').downcase
    elsif ENV['ANTHROPIC_API_KEY']
      key = ENV['ANTHROPIC_API_KEY']
      name = 'anthropic'
    elsif ENV['OPENAI_API_KEY']
      key = ENV['OPENAI_API_KEY']
      name = 'openai'
    elsif ENV['GOOGLE_API_KEY']
      key = ENV['GOOGLE_API_KEY']
      name = 'google'
    else
      return nil
    end

    factory = PROVIDERS[name]
    raise "Unknown LLM provider: #{name}. Available: #{PROVIDERS.keys.join(', ')}" unless factory

    factory.call(key)
  end

  private_class_method :resolve_provider
end
