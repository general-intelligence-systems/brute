# Getting Started

This guide walks you through installing Brute and running your first coding agent.

## Install

```ruby
gem "brute" # requires Ruby >= 3.2
```

## Setup

Brute uses [RubyLLM](https://rubyllm.com) under the hood, which auto-detects your LLM provider from environment variables:

```bash
export ANTHROPIC_API_KEY=sk-...              # Claude
export OPENAI_API_KEY=sk-...                 # GPT / o-series
export GOOGLE_API_KEY=AIza...                # Gemini
export OLLAMA_HOST=http://localhost:11434     # Local Ollama (no key needed)
```

Or set explicitly:

```bash
export LLM_API_KEY=your-key
export LLM_PROVIDER=anthropic  # openai | google | deepseek | ollama | xai
```

## Example

This is a complete, runnable script. It creates an agent with tools and a middleware pipeline, then runs three turns against a shared session -- creating a file, modifying it, and reading it back, all autonomously.

```ruby
require "brute"

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

Brute::Session.new(path: "tmp/session.jsonl").then do |session|
  session.user("Create a file called config.yml with settings for a web app: port, host, database_url, log_level.")
  agent.call(session)

  session.user("Change the port to 8080 and add a redis_url setting.")
  agent.call(session)

  session.user("Read config.yml and summarize all the settings.")
  agent.call(session)
end
```

### What just happened?

- **Turn 1** -- The agent used its `write` tool to create `config.yml` with the requested settings.
- **Turn 2** -- Same session. The agent remembered the file it just created, used `read` to open it, then `patch` to update the port and add `redis_url`.
- **Turn 3** -- The agent read the file back and returned a plain-text summary.

All three turns share one session, so the agent has full conversational context throughout. The middleware pipeline handles system prompt injection, tool execution loops, iteration limits, and event output automatically.

### Key concepts

- **`Brute.provider`** -- returns the configured LLM provider (defaults to `:anthropic`).
- **`Brute::Agent`** -- a middleware pipeline that accepts a provider, model, tools, and a block configuring the middleware stack.
- **`Brute::Session`** -- an array of messages with optional JSONL persistence via the `path:` argument.
- **`session.user(...)`** -- appends a user message and auto-persists it.
- **`agent.call(session)`** -- runs the full middleware pipeline, invoking the LLM and executing tool calls until the agent is done.
