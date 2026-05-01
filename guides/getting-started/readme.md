# Getting Started

This guide walks you through installing Brute and running your first coding agent.

## Install

```ruby
gem "brute" # requires Ruby >= 3.2
```

## Setup

Brute auto-detects your LLM provider from environment variables (checked in order):

```sh
export ANTHROPIC_API_KEY=sk-...              # Claude
export OPENAI_API_KEY=sk-...                 # GPT / o-series
export GOOGLE_API_KEY=AIza...                # Gemini
export OLLAMA_HOST=http://localhost:11434     # Local Ollama (no key needed)
```

Or set explicitly:

```sh
export LLM_API_KEY=your-key
export LLM_PROVIDER=anthropic  # openai | google | deepseek | ollama | xai
```

## Example

This is a complete, runnable script. It creates an agent, queues three turns against a shared session, and lets the agent create a file, modify it, then read it back -- all autonomously.

```ruby
require "brute"

provider = Brute::Providers.guess_from_env
session  = Brute::Store::Session.new

agent = Brute::Agent.new(
  provider:      provider,
  model:         provider.default_model,
  tools:         Brute::Tools::ALL,
  system_prompt: Brute::SystemPrompt.default.prepare(
    provider_name: provider.name.to_s,
    model_name:    provider.default_model.to_s,
    cwd:           Dir.pwd,
  ).to_s
)

pipeline = Brute::Pipeline.new do
  use Brute::Middleware::Tracing,
    logger: Logger.new($stderr, level: Logger::INFO)
  use Brute::Middleware::Retry
  use Brute::Middleware::SessionPersistence, session: session
  use Brute::Middleware::TokenTracking
  use Brute::Middleware::ToolErrorTracking
  use Brute::Middleware::DoomLoopDetection
  use Brute::Middleware::ToolUseGuard
  run Brute::Middleware::LLMCall.new
end

Sync do
  queue = Brute::Queue::SequentialQueue.new
  [
    "Create a file called config.yml with settings for a web app: port, host, database_url, log_level.",
    "Change the port to 8080 and add a redis_url setting.",
    "Read config.yml and summarize all the settings.",
  ].each do |input|
    queue << Brute::Loop::AgentTurn.new(
      input: input, agent: agent, session: session, pipeline: pipeline,
    )
  end
  queue.start
  queue.drain
end
```

### What just happened?

- **Turn 1** -- The agent used its `write` tool to create `config.yml` with the requested settings.
- **Turn 2** -- Same session. The agent remembered the file it just created, used `read` to open it, then `patch` to update the port and add `redis_url`.
- **Turn 3** -- The agent read the file back and returned a plain-text summary.

All three turns share one session, so the agent has full conversational context throughout. The middleware pipeline handles retries, token tracking, compaction, doom loop detection, and session persistence automatically.
