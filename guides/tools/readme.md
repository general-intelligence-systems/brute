# Tools

Brute ships with 12 built-in tools that give the agent access to the filesystem, network, task management, and skills.

## Built-in Tools

| Tool | Class | Purpose |
|------|-------|---------|
| `read` | `FSRead` | Read files (supports line ranges) |
| `write` | `FSWrite` | Create/overwrite files |
| `patch` | `FSPatch` | Find-and-replace in files |
| `remove` | `FSRemove` | Delete files/directories |
| `fs_search` | `FSSearch` | Ripgrep content search with glob filter |
| `undo` | `FSUndo` | Revert last file mutation |
| `shell` | `Shell` | Execute commands (5 min timeout, 50KB cap) |
| `fetch` | `NetFetch` | HTTP GET |
| `todo_write` | `TodoWrite` | Replace task list |
| `todo_read` | `TodoRead` | Read task list |
| `question` | `Question` | Ask user interactive questions |
| `skill` | `SkillLoad` | Load a skill's full instructions + bundled files ([skills guide](../skills/readme.md)) |

## Using Tools

Pass tools when creating an agent. Use `Brute::Tools::ALL` for the full set:

```ruby
agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end
```

For a restricted, read-only agent:

```ruby
agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    [Brute::Tools::FSRead, Brute::Tools::FSSearch],
) do
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end
```

## Sub-Agent Delegation

For delegating tasks to other agents, use `Brute::SubAgent` rather than a built-in tool. Sub-agents are wrapped as tools via `.to_ruby_llm` and registered in the parent agent's tool list:

```ruby
explorer = Brute::SubAgent.new(
  name:        "explore_code",
  description: "Delegate a code exploration task to a read-only sub-agent.",
  provider:    Brute.provider,
  model:       "claude-sonnet-4-20250514",
  tools:       [Brute::Tools::FSRead, Brute::Tools::FSSearch],
) do
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::Summarize
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations, max_iterations: 15
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

# Register the sub-agent as a tool in the parent agent
agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    [explorer.to_ruby_llm],
) do
  # ...
end
```

See `examples/07_subagent_exploration.rb` for a full working example with parallel sub-agents.
