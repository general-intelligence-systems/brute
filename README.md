# Brute

Production-grade coding agent framework for Ruby. Rack-style middleware pipeline, concurrent tool execution, multi-provider LLM support, session persistence, context compaction, and doom loop detection -- all built on [llm.rb](https://rubygems.org/gems/llm.rb).

## Install

```ruby
gem "brute" # requires Ruby >= 3.2
```

## Quick Start

```ruby
require "brute"

agent = Brute.agent(cwd: Dir.pwd)
response = agent.run("Read app.rb and fix any bugs")
puts response.content
```

Provider is auto-detected from environment variables (checked in order):

```sh
export ANTHROPIC_API_KEY=sk-...    # Claude
export OPENAI_API_KEY=sk-...       # GPT / o-series
export GOOGLE_API_KEY=AIza...      # Gemini
```

Or set explicitly:

```sh
export LLM_API_KEY=your-key
export LLM_PROVIDER=anthropic  # openai | google | deepseek | ollama | xai
```

## Streaming Callbacks

```ruby
agent = Brute.agent(
  cwd: Dir.pwd,
  on_content:        ->(text)  { print text },
  on_reasoning:      ->(text)  { print text },
  on_tool_call_start: ->(tools) { puts tools.map { |t| t[:name] }.join(", ") },
  on_tool_result:    ->(name, val) { puts "#{name} done" },
  on_question:       ->(questions, queue) { queue << answers },
)
agent.run("Refactor the auth module")
```

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

```ruby
# Use tools directly
Brute::Tools::FSRead.new.call(file_path: "app.rb")
Brute::Tools::FSPatch.new.call(file_path: "app.rb", old_string: "foo", new_string: "bar")
Brute::Tools::Shell.new.call(command: "bundle exec rspec", cwd: "/project")
Brute::Tools::FSSearch.new.call(pattern: "def initialize", path: ".", glob: "*.rb")
```

## Middleware Pipeline

Every LLM call passes through a Rack-style middleware chain:

```
OTel → Tracing → Retry → Session → Messages → Tokens → Compaction → ToolErrors → DoomLoop → Reasoning → ToolGuard → [LLM Call]
```

### Build a Custom Pipeline

```ruby
pipeline = Brute::Pipeline.new do
  use Brute::Middleware::Tracing, logger: logger
  use Brute::Middleware::Retry, max_attempts: 3, base_delay: 2
  use Brute::Middleware::TokenTracking
  run Brute::Middleware::LLMCall.new
end
pipeline.call(env)
```

### Write Custom Middleware

```ruby
class MyMiddleware < Brute::Middleware::Base
  def call(env)
    # before
    result = @app.call(env)
    # after
    result
  end
end
```

### Short-Circuit

```ruby
class RateLimiter < Brute::Middleware::Base
  def call(env)
    return { error: "rate limited" } if over_limit?
    @app.call(env)
  end
end
```

## Sessions

```ruby
# Create and use
session = Brute::Session.new
agent = Brute.agent(session: session)
agent.run("Start the feature")

# Resume later
sessions = Brute::Session.list          # newest first
session = Brute::Session.new(id: sessions.first[:id])
agent = Brute.agent(session: session)
agent.run("Continue where we left off")

# Clean up
session.delete
```

## Context Compaction

Automatically summarizes old messages when context grows too large:

```ruby
compactor = Brute::Compactor.new(provider,
  token_threshold:   100_000, # compact above this token count
  message_threshold: 200,     # compact above this message count
  retention_window:  6,       # keep N most recent messages
)

if compactor.should_compact?(messages, usage: token_usage)
  summary, recent = compactor.compact(messages)
end
```

## Doom Loop Detection

Detects when the agent repeats the same tool calls in a loop:

```ruby
detector = Brute::DoomLoopDetector.new(threshold: 3)

reps = detector.detect(messages)   # returns count or nil
puts detector.warning_message(reps) if reps
# => "You've repeated the same tool call pattern 3 times..."
```

Catches both consecutive identical calls (`A,A,A`) and repeating sequences (`A,B,A,B,A,B`).

## Lifecycle Hooks

```ruby
class MetricsHook < Brute::Hooks::Base
  private
  def on_start(**)            = StatsD.increment("agent.start")
  def on_end(**)              = StatsD.increment("agent.end")
  def on_request(**)          = StatsD.increment("agent.request")
  def on_response(**)         = StatsD.increment("agent.response")
  def on_toolcall_start(**k)  = StatsD.increment("tool.#{k[:tool_name]}")
  def on_toolcall_end(**k)    = StatsD.increment("tool.#{k[:tool_name]}.done")
end

# Compose multiple hooks
hooks = Brute::Hooks::Composite.new(MetricsHook.new, Brute::Hooks::Logging.new(logger))
hooks.call(:start)
```

## File Undo (Copy-on-Write)

Every file mutation snapshots the previous state:

```ruby
Brute::SnapshotStore.save("/path/to/file.rb")   # before mutation
Brute::SnapshotStore.depth("/path/to/file.rb")   # => 1
content = Brute::SnapshotStore.pop("/path/to/file.rb")  # restore
```

## System Prompt

Provider-aware prompt assembly with per-provider stacks (Anthropic, OpenAI, Google, default):

```ruby
prompt = Brute::SystemPrompt.default
result = prompt.prepare(
  provider_name: "anthropic",
  model_name: "claude-sonnet-4-20250514",
  cwd: Dir.pwd,
  custom_rules: "Always use RSpec.",
  agent: "build",
)
puts result.to_s
```

## Skills

Discovers `SKILL.md` files from `.brute/skills/` (project) and `~/.config/brute/skills/` (global):

```ruby
Brute::Skill.all(cwd: Dir.pwd)          # => [Skill::Info, ...]
skill = Brute::Skill.get("tdd", cwd: Dir.pwd)
puts skill.content
```

## Providers

| Name | Auto-detect env var |
|------|-------------------|
| `anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `OPENAI_API_KEY` |
| `google` | `GOOGLE_API_KEY` |
| `deepseek` | `LLM_API_KEY` + `LLM_PROVIDER=deepseek` |
| `ollama` | `LLM_API_KEY` + `LLM_PROVIDER=ollama` |
| `xai` | `LLM_API_KEY` + `LLM_PROVIDER=xai` |
| `opencode_zen` | `OPENCODE_API_KEY` |
| `opencode_go` | `OPENCODE_API_KEY` |
| `shell` | (always available) |

```ruby
Brute.configured_providers  # => ["anthropic", "opencode_zen", "shell"]
Brute.provider_for("openai") # => LLM::OpenAI instance
```

## OpenTelemetry

When `opentelemetry-sdk` is loaded, the pipeline automatically emits spans, tool call/result events, and token usage attributes. No-op when the SDK is absent.

## Configuration Reference

| Option | Default | Where |
|--------|---------|-------|
| `token_threshold` | 100,000 | `Compactor` |
| `message_threshold` | 200 | `Compactor` |
| `retention_window` | 6 | `Compactor` |
| `max_attempts` | 3 | `Middleware::Retry` |
| `base_delay` | 2s | `Middleware::Retry` |
| `max_failures` | 3 per tool | `Middleware::ToolErrorTracking` |
| `MAX_REQUESTS_PER_TURN` | 100 | `Orchestrator` |
| `TIMEOUT` | 300s | `Tools::Shell` |
| `MAX_OUTPUT` | 50KB | `Tools::Shell` |

## License

MIT
