# Brute

Production-grade coding agent framework for Ruby. Built on [llm.rb](https://rubygems.org/gems/llm.rb).

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

This is a complete, runnable script. It creates an agent, queues three turns against a shared session, and lets the agent create a file, modify it, then read it back — all autonomously.

```ruby
require "brute"

# 1. Pick a provider (auto-detected from env vars above)
provider = Brute::Providers.guess_from_env

# 2. Create a session (keeps conversation history across turns)
session       = Brute::Store::Session.new
message_store = session.message_store

# 3. Build the system prompt
system_prompt = Brute::SystemPrompt.default.prepare(
  provider_name: provider.name.to_s,
  model_name:    provider.default_model.to_s,
  cwd:           Dir.pwd,
).to_s

# 4. Build the middleware pipeline
compactor = Brute::Loop::Compactor.new(provider)
logger    = Logger.new($stderr, level: Logger::INFO)

pipeline = Brute::Pipeline.new do
  use Brute::Middleware::Tracing, logger: logger
  use Brute::Middleware::Retry
  use Brute::Middleware::SessionPersistence, session: session
  use Brute::Middleware::MessageTracking, store: message_store
  use Brute::Middleware::TokenTracking
  use Brute::Middleware::CompactionCheck,
    compactor: compactor,
    system_prompt: system_prompt
  use Brute::Middleware::ToolErrorTracking
  use Brute::Middleware::DoomLoopDetection
  use Brute::Middleware::ToolUseGuard
  run Brute::Middleware::LLMCall.new
end

# 5. Create the agent
agent = Brute::Agent.new(
  provider:      provider,
  model:         provider.default_model,
  tools:         Brute::Tools::ALL,
  system_prompt: system_prompt,
)

# 6. Queue three turns — the agent will execute them in order
Sync do
  queue = Brute::Queue::SequentialQueue.new

  queue << Brute::Loop::AgentTurn.new(
    agent: agent, session: session, pipeline: pipeline,
    input: "Create a file called config.yml with settings for a web app: port, host, database_url, log_level.",
  )

  queue << Brute::Loop::AgentTurn.new(
    agent: agent, session: session, pipeline: pipeline,
    input: "Change the port to 8080 and add a redis_url setting.",
  )

  queue << Brute::Loop::AgentTurn.new(
    agent: agent, session: session, pipeline: pipeline,
    input: "Read config.yml and summarize all the settings.",
  )

  queue.start
  queue.drain

  queue.steps.each_with_index do |step, i|
    puts "Turn #{i + 1}: #{step.state}"
  end
end
```

### What just happened?

- **Turn 1** — The agent used its `write` tool to create `config.yml` with the requested settings.
- **Turn 2** — Same session. The agent remembered the file it just created, used `read` to open it, then `patch` to update the port and add `redis_url`.
- **Turn 3** — The agent read the file back and returned a plain-text summary.

All three turns share one session, so the agent has full conversational context throughout. The middleware pipeline handles retries, token tracking, compaction, doom loop detection, and session persistence automatically.

## Tools (12 built-in)

| Tool | Purpose |
|------|---------|
| `read` | Read files (supports line ranges) |
| `write` | Create/overwrite files |
| `patch` | Find-and-replace in files |
| `remove` | Delete files/directories |
| `fs_search` | Ripgrep content search with glob filter |
| `undo` | Revert last file mutation |
| `shell` | Execute commands (5 min timeout, 50KB cap) |
| `fetch` | HTTP GET |
| `todo_write` | Replace task list |
| `todo_read` | Read task list |
| `delegate` | Spawn read-only sub-agent |
| `question` | Ask user interactive questions |

## Providers

| Name | Auto-detect env var |
|------|-------------------|
| `anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `OPENAI_API_KEY` |
| `google` | `GOOGLE_API_KEY` |
| `deepseek` | `LLM_API_KEY` + `LLM_PROVIDER=deepseek` |
| `ollama` | `OLLAMA_HOST` (no key needed) |
| `xai` | `LLM_API_KEY` + `LLM_PROVIDER=xai` |

## More Examples

See the [`examples/`](examples/) directory for more:

- `01_basic_agent.rb` — Ask a question, get a response
- `02_fix_a_bug.rb` — Agent reads a buggy file, patches it, runs tests to verify
- `03_session_persistence.rb` — Two turns sharing the same session
- `04_custom_rules.rb` — Inject project-specific rules into the system prompt
- `05_multi_turn.rb` — Three sequential turns with a shared session (this README example)
- `06_read_only_agent.rb` — Restricted tool set, read-only code analysis
- `07_agent_turn.rb` — Single turn, no tools

## License

MIT
