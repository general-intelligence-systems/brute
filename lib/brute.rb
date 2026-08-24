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

# Explicit, in dependency order: Hooks and Middleware::Base are included and
# inherited at load time, so they cannot be left to a sorted glob that happens
# to reach completion/ before hooks.
require_relative "brute/version"
require_relative "brute/hooks"
require_relative "brute/messages"
require_relative "brute/middleware/000_base"
require_relative "brute/completion/open_router"
require_relative "brute/completion/lang_chain"
require_relative "brute/completion/llmrb"
require_relative "brute/completion/ruby_llm"
require_relative "brute/usage_detection/usage"
require_relative "brute/usage_detection/open_router"
require_relative "brute/usage_detection/ruby_llm"
require_relative "brute/usage_detection/llmrb"
require_relative "brute/usage_detection/lang_chain"
require_relative "brute/contrib/log_file"
require_relative "brute/contrib/otel"
require_relative "brute/events/handler"
require_relative "brute/events/prefixed_terminal_output"
require_relative "brute/events/terminal_output_handler"
require_relative "brute/message_transport"
require_relative "brute/message_transport/anthropic"
require_relative "brute/message_transport/llm"
require_relative "brute/message_transport/open_router"
require_relative "brute/message_transport/openai"
require_relative "brute/message_transport/ruby_llm"
require_relative "brute/message_transport/ruby_open_ai"
require_relative "brute/message_transport/lang_chain"
require_relative "brute/middleware/002_session_log"
require_relative "brute/middleware/004_summarize"
require_relative "brute/middleware/006_loop"
require_relative "brute/middleware/008_checkpoint"
require_relative "brute/middleware/010_max_iterations"
require_relative "brute/middleware/020_system_prompt"
require_relative "brute/middleware/025_skills"
require_relative "brute/middleware/040_compaction_check"
require_relative "brute/middleware/060_questions"
require_relative "brute/middleware/070_tool_pipeline"
require_relative "brute/middleware/event_handler"
require_relative "brute/middleware/user_queue"
require_relative "brute/prompt_template"
require_relative "brute/prompts"
require_relative "brute/prompts/autonomy"
require_relative "brute/prompts/base"
require_relative "brute/prompts/build_switch"
require_relative "brute/prompts/code_references"
require_relative "brute/prompts/code_style"
require_relative "brute/prompts/conventions"
require_relative "brute/prompts/doing_tasks"
require_relative "brute/prompts/editing_approach"
require_relative "brute/prompts/editing_constraints"
require_relative "brute/prompts/environment"
require_relative "brute/prompts/frontend_tasks"
require_relative "brute/prompts/git_safety"
require_relative "brute/prompts/identity"
require_relative "brute/prompts/instructions"
require_relative "brute/prompts/max_steps"
require_relative "brute/prompts/objectivity"
require_relative "brute/prompts/plan_reminder"
require_relative "brute/prompts/proactiveness"
require_relative "brute/prompts/security_and_safety"
require_relative "brute/prompts/skills"
require_relative "brute/prompts/task_management"
require_relative "brute/prompts/tone_and_style"
require_relative "brute/prompts/tool_usage"
require_relative "brute/rack/adapter"
require_relative "brute/skill"
require_relative "brute/system_prompt"
require_relative "brute/tool"
require_relative "brute/tools"
require_relative "brute/tools/adapter"
require_relative "brute/tools/fs/file_mutation_queue"
require_relative "brute/tools/fs/snapshot_store"
require_relative "brute/tools/fs_patch"
require_relative "brute/tools/fs_read"
require_relative "brute/tools/fs_remove"
require_relative "brute/tools/fs_search"
require_relative "brute/tools/fs_undo"
require_relative "brute/tools/fs_write"
require_relative "brute/tools/net_fetch"
require_relative "brute/tools/question"
require_relative "brute/tools/shell"
require_relative "brute/tools/skill_load"
require_relative "brute/tools/sub_agent"
require_relative "brute/tools/todo_list/store"
require_relative "brute/tools/todo_read"
require_relative "brute/tools/todo_write"
require_relative "brute/truncation"
require_relative "brute/turn/agent_pipeline"
require_relative "brute/turn/pipeline"
require_relative "brute/turn/tool_pipeline"
require_relative "brute/utils/diff"

# gangsta g-dogg bruh...
