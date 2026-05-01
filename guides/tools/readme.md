# Tools

Brute ships with 12 built-in tools that give the agent full access to the filesystem, network, and task management.

## Built-in Tools

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

## Using Tools

Pass tools when creating an agent:

```ruby
agent = Brute::Agent.new(
  provider: provider,
  model:    provider.default_model,
  tools:    Brute::Tools::ALL,
)
```

For a restricted, read-only agent:

```ruby
agent = Brute::Agent.new(
  provider: provider,
  model:    provider.default_model,
  tools:    [Brute::Tools::FsRead, Brute::Tools::FsSearch],
)
```
