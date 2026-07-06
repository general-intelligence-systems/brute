---
layout: default
title: Getting Started
nav_order: 1
description: Install brute, build your first agent with the LLM library of your choice, and run a multi-step coding task.
---

# Getting Started

This guide installs brute, builds a working coding agent, and runs a multi-step task against a local or hosted model.

## Installation

```ruby
# Gemfile
gem "brute"

# plus the LLM library you want to call — brute depends on none of them
gem "ruby_llm"    # or "llm.rb", "openai", "anthropic"
```

Requires Ruby >= 3.3.

## The shape of an agent

`Brute.agent` returns an `AgentPipeline` — a Rack-style builder that is also the runnable agent. You chain `.use` for middleware and `.run` for the terminal LLM-call proc (both return the pipeline), then invoke it with `.start(prompt)`:

```ruby
agent = Brute.agent
  .use(SomeMiddleware)
  .run ->(env) { ... }     # the LLM call — provider/model/credentials live HERE

env = agent.start("do the thing")
env[:messages].last.content   # the agent's final answer
```

There is no agent-level configuration. Tools go to the `ToolPipeline` middleware, the conversation log to `SessionLog`, and everything about the LLM (provider, model, keys) lives inside the `run` proc.

## A complete agent

This is `examples/ruby_llm.rb`, trimmed. It defaults to a local [Ollama](https://ollama.com); set `BRUTE_PROVIDER` / `BRUTE_MODEL` / an API key to use a hosted model.

```ruby
require "brute"
require "ruby_llm"

PROVIDER = ENV.fetch("BRUTE_PROVIDER", "ollama").to_sym
MODEL    = ENV.fetch("BRUTE_MODEL", "llama3.2")

# Advertise Brute's tools to ruby_llm: each neutral adapter (name,
# description, JSON schema via #to_h) becomes a RubyLLM::Tool.
def rubyllm_tools(tools)
  Brute.tools(tools).transform_values do |adapter|
    schema = adapter.to_h[:parameters]
    Class.new(RubyLLM::Tool) do
      description adapter.description
      params schema
      define_method(:name) { adapter.name }
      define_method(:execute) { |**args| adapter.call(args) }
    end.new
  end
end

agent = Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    context = RubyLLM.context do |config|
      config.ollama_api_base   = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
      config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
    end

    model, provider = RubyLLM::Models.resolve(
      MODEL, provider: PROVIDER, assume_exists: true, config: context.config
    )

    response = provider.complete(
      Brute::MessageTransport::RubyLLM.dump_all(env[:messages]),
      tools:       rubyllm_tools(env[:tools]),
      temperature: 0.7,
      model:       model,
    )

    Brute::MessageTransport::RubyLLM.wrap_each(response) do |message|
      env[:messages] << message
    end
  end

env = agent.start("What files are in the current directory? List them.")
puts env[:messages].last.content
```

Run it:

```sh
ruby examples/ruby_llm.rb

# or against Anthropic:
BRUTE_PROVIDER=anthropic BRUTE_MODEL=claude-opus-4-8 ANTHROPIC_API_KEY=sk-... ruby examples/ruby_llm.rb
```

## What happens in a turn

1. `.start("...")` builds the env: `{ messages:, events:, metadata:, current_iteration: }`, with your prompt as a `role: :user` message.
2. Middleware runs top-down: `SessionLog` loads history from disk, `SystemPrompt` prepends the system message, `ToolPipeline` advertises the tools on `env[:tools]`.
3. Your `run` proc converts `env[:messages]` to the library's format (the [MessageTransport]({% link _core_features/message-transports.md %}) does this), makes ONE completion, and appends the response back as `Brute::Message` values.
4. On the way back up, `ToolPipeline` executes any tool calls the model made — concurrently, with output truncation — and appends `role: :tool` results.
5. `Loop::ToolResult` sees the last message is a tool result and sends control back down. The loop ends when the model answers with text (or `MaxIterations` trips).
6. `SessionLog` persists the whole conversation as JSONL.

Every message in `env[:messages]` is a [`Brute::Message`]({% link _core_features/messages.md %}) — a plain, immutable value. Nothing in that flow touched an LLM library except your proc.

## Not a ruby_llm shop?

The identical agent runs on [llm.rb, the openai gem, or the anthropic gem]({% link _core_features/message-transports.md %}) — only the `run` proc changes. See `examples/llm.rb`, `examples/openai.rb`, and `examples/anthropic.rb` in the repo, or the [examples overview]({% link _examples/examples.md %}).
