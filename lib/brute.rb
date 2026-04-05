# frozen_string_literal: true

require "llm"
require "timeout"
require "logger"

# Brute — a coding agent built on llm.rb
#
# Cross-cutting concerns are implemented as Rack-style middleware in a
# Pipeline that wraps every LLM call:
#
#   Tracing → Retry → Session → Tokens → Compaction → ToolErrors → DoomLoop → Reasoning → [LLM Call]
#
module Brute
  module Tools; end
  module Hooks; end
  module Middleware; end
end

# Infrastructure
require_relative "brute/snapshot_store"
require_relative "brute/todo_store"
require_relative "brute/file_mutation_queue"
require_relative "brute/doom_loop"
require_relative "brute/hooks"
require_relative "brute/compactor"
require_relative "brute/system_prompt"
require_relative "brute/session"
require_relative "brute/pipeline"
require_relative "brute/agent_stream"

# Provider patches
require_relative "brute/patches/anthropic_tool_role"
require_relative "brute/patches/buffer_nil_guard"

# Middleware (Rack-style)
require_relative "brute/middleware/base"
require_relative "brute/middleware/llm_call"
require_relative "brute/middleware/retry"
require_relative "brute/middleware/doom_loop_detection"
require_relative "brute/middleware/token_tracking"
require_relative "brute/middleware/compaction_check"
require_relative "brute/middleware/session_persistence"
require_relative "brute/middleware/tracing"
require_relative "brute/middleware/tool_error_tracking"
require_relative "brute/middleware/reasoning_normalizer"

# Tools
require_relative "brute/tools/fs_read"
require_relative "brute/tools/fs_write"
require_relative "brute/tools/fs_patch"
require_relative "brute/tools/fs_remove"
require_relative "brute/tools/fs_search"
require_relative "brute/tools/fs_undo"
require_relative "brute/tools/shell"
require_relative "brute/tools/net_fetch"
require_relative "brute/tools/todo_write"
require_relative "brute/tools/todo_read"
require_relative "brute/tools/delegate"

# Orchestrator (depends on tools, middleware, and infrastructure)
require_relative "brute/orchestrator"

module Brute
  VERSION = "0.1.0"

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
  ].freeze

  # Default provider, resolved from environment.
  def self.provider
    @provider ||= resolve_provider
  end

  def self.provider=(p)
    @provider = p
  end

  # Create a new orchestrator with sensible defaults.
  def self.agent(cwd: Dir.pwd, tools: TOOLS, session: nil, reasoning: {}, **callbacks)
    Orchestrator.new(
      provider: provider,
      tools: tools,
      cwd: cwd,
      session: session,
      reasoning: reasoning,
      **callbacks
    )
  end

  def self.resolve_provider
    if (key = ENV["LLM_API_KEY"] || ENV["ANTHROPIC_API_KEY"])
      LLM.anthropic(key: key).tap { Patches::AnthropicToolRole.apply! }
    elsif ENV["OPENAI_API_KEY"]
      LLM.openai(key: ENV["OPENAI_API_KEY"])
    elsif ENV["GOOGLE_API_KEY"]
      LLM.google(key: ENV["GOOGLE_API_KEY"])
    end
    # Returns nil if no key — error deferred to Orchestrator#run
  end

  private_class_method :resolve_provider
end
