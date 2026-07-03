# frozen_string_literal: true
#
# A brute.ru file — the Brute analogue of a rackup config.ru. It describes an
# agent turn with the same `use` / `run` DSL, and is loaded with:
#
#   agent = Brute::Turn::AgentPipeline.parse_file("examples/agents/brute.ru")
#   env = agent.start("What files are in the current directory?")
#
# Brute manages the turn here: ToolPipeline advertises + runs the tools, and the
# terminal `run` proc makes one LLM call and owns all LLM config. Defaults to a
# local Ollama; override with BRUTE_PROVIDER / BRUTE_MODEL / OLLAMA_API_BASE.

use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
use Brute::Middleware::SystemPrompt
use Brute::Middleware::Loop::ToolResult
use Brute::Middleware::MaxIterations
use Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL

run ->(env) do
  context = RubyLLM.context do |config|
    config.ollama_api_base   = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
    config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
    config.openai_api_key    = ENV["OPENAI_API_KEY"]
  end

  model, provider = RubyLLM::Models.resolve(
    ENV.fetch("BRUTE_MODEL", "llama3.2"),
    provider:      ENV.fetch("BRUTE_PROVIDER", "ollama").to_sym,
    assume_exists: true,
    config:        context.config,
  )

  response = provider.complete(
    env[:messages],
    tools:       Brute.rubyllm_tools(env[:tools]),
    temperature: 0.7,
    model:       model,
  )

  RubyLLM::MessageTransport.new(response).wrap_each { |message| env[:messages] << message }
end
