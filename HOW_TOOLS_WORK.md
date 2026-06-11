# How Tools Work

A tool is anything the LLM can invoke by name with structured arguments: read a
file, run a shell command, update the todo list, delegate to a sub-agent. This
document traces how tools are defined, how they are advertised to the model, and how
a tool call travels through the middleware pipeline and back.

The key files:

- `lib/brute/tools.rb` — the built-in tool registry (`Brute::Tools::ALL`)
- `lib/brute/tools/*.rb` — the built-in tools (`RubyLLM::Tool` subclasses)
- `lib/brute/tools/adapter.rb` — normalizes any tool shape into one interface
- `lib/brute/tool.rb` — `Brute::Tool`, a middleware-pipeline tool
- `lib/brute/tools/sub_agent.rb` — an agent wearing a tool-shaped facade
- `lib/brute/middleware/070_tool_call.rb` — executes pending tool calls
- `lib/brute/middleware/003_tool_result_loop.rb` — re-runs the loop on tool results

## The four ways to define a tool

Brute accepts tools in several shapes; you pick based on how much machinery you
need. All of them are normalized by `Brute::Tools::Adapter` (see below), so the
rest of the framework never cares which one you used.

### 1. `RubyLLM::Tool` subclass — how the built-ins are written

```ruby
class FSRead < RubyLLM::Tool
  description "Read the contents of a file..."
  param :file_path, type: 'string', desc: "Path to the file", required: true
  def name; "read"; end
  def execute(file_path:, **) ... end
end
```

This gives you ruby_llm's param schema DSL and argument validation for free.

### 2. Inline `Hash` — the quickest way to add a tool

```ruby
{
  name:        "echo",
  description: "Echo the input back",
  params:      { msg: { type: "string", required: true } },
  execute:     ->(msg:) { msg },
}
```

A plain hash with an `:execute` proc is a complete tool
(`Adapter.from_hash`, `lib/brute/tools/adapter.rb:79`).

### 3. `Brute::Tool` — when the tool itself needs middleware

`Brute::Tool` (`lib/brute/tool.rb`) is a `Pipeline` configured for tool execution:
the terminal app does the work, and middleware wraps it with concerns like param
validation, file-mutation queueing, snapshotting, or logging.

```ruby
read = Brute::Tool.new(
  name:        "read",
  description: "Read a file's contents",
  params:      { file_path: { type: "string", required: true } },
) do
  use Brute::Middleware::Tool::ValidateParams
  run ->(env) { env[:result] = File.read(File.expand_path(env[:arguments][:file_path])) }
end
```

Arguments arrive in `env[:arguments]`; the result is whatever the terminal app puts
in `env[:result]` (`lib/brute/tool.rb:43-53`).

### 4. `Brute::Tools::SubAgent` — an agent as a tool

A `SubAgent` (`lib/brute/tools/sub_agent.rb`) is an `Agent` subclass that exposes
`name`/`description`/`params`/`execute`, so it drops straight into another agent's
tools list. When the parent's LLM invokes it, the sub-agent builds a fresh
`Session` from the `task` argument, runs its own full middleware pipeline, and
returns its final assistant message as the tool result. This is how delegation and
parallel exploration work (see `guides/tools/readme.md`).

Anything else that quacks like a tool — responds to `#name` plus `#call` or
`#execute` — is also accepted via duck typing
(`Adapter.from_duck_type`, `lib/brute/tools/adapter.rb:113`).

## The Adapter: one neutral interface

`Brute::Tools::Adapter.wrap(tool)` (`lib/brute/tools/adapter.rb`) converts any of
the shapes above into a uniform object:

```ruby
adapter.name        # String
adapter.description # String
adapter.params      # { key => { type:, desc:, required: } }
adapter.call(args)  # execute with a string- or symbol-keyed Hash
```

`Adapter.wrap_all(tools)` turns an agent's tool list into the
`{ name_sym => adapter }` lookup hash that the execution middleware works with.
Adapters also convert outward in two directions, depending on how the completion
middleware talks to the provider:

- `#to_ruby_llm` — builds a `RubyLLM::Tool` so ruby_llm-backed completion can hand
  the tool to its providers (`lib/brute/tools/adapter.rb:153`).
- `#to_h` — a library-neutral JSON-Schema-ish definition for completion middlewares
  that hit an HTTP API directly (`lib/brute/tools/adapter.rb:167`).

Classes are instantiated automatically (`tool.new if tool.is_a?(Class)`), and
wrapping is idempotent.

## The built-in tools

`Brute::Tools::ALL` (`lib/brute/tools.rb`) is the full set of 11:

| Tool name   | Class      | Purpose |
|-------------|------------|---------|
| `read`      | `FSRead`   | Read files — line ranges, 2000-line/50 KB caps, binary detection, directory listing, "did you mean" suggestions |
| `write`     | `FSWrite`  | Create or overwrite files |
| `patch`     | `FSPatch`  | Find-and-replace edits in files |
| `remove`    | `FSRemove` | Delete files/directories |
| `fs_search` | `FSSearch` | Ripgrep content search with glob filter |
| `undo`      | `FSUndo`   | Revert the last file mutation (via snapshots) |
| `shell`     | `Shell`    | Execute commands (5 min timeout, 50 KB cap) |
| `fetch`     | `NetFetch` | HTTP GET |
| `todo_write`| `TodoWrite`| Replace the task list |
| `todo_read` | `TodoRead` | Read the task list |
| `question`  | `Question` | Ask the user interactive questions |

File-mutating tools share two pieces of infrastructure under `lib/brute/tools/fs/`:
`FileMutationQueue` serializes concurrent mutations to the same file (using a
fiber-scheduler-aware mutex, so different files still proceed in parallel), and
`SnapshotStore` records pre-mutation copies that `undo` restores.

You hand tools to an agent at construction:

```ruby
agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,            # or a restricted subset
) do
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end
```

## The execution flow

A single user turn with tool use moves through the middleware stack like this:

```
ToolResultLoop                        (outer loop)
  └─ MaxIterations                    (guard: sets env[:should_exit])
       └─ ToolCall                    (executes pending calls after completion)
            └─ Completion / LLMCall   (sends messages + tool defs to the provider)
```

1. **Advertise.** The completion middleware converts the agent's tool list into
   provider format (via `to_ruby_llm` or `to_h`) and sends it with the
   conversation. The system prompt's tool-usage section
   (`lib/brute/prompts/text/tool_usage/*.txt`, selected per provider) tells the
   model *how* to use them — parallel calls, preferring `read`/`patch` over shell
   equivalents, etc.

2. **Respond.** The LLM's assistant message comes back, possibly carrying
   `tool_calls`.

3. **Execute** (`Middleware::ToolCall`, `lib/brute/middleware/070_tool_call.rb`).
   After the inner stack returns, ToolCall collects pending tool calls from the
   last message (the `question` tool is excluded — it's handled interactively,
   `lib/brute/middleware/070_tool_call.rb:124-126`) and runs them **concurrently**
   with the `async` gem: each call becomes a task inside an `Async::Barrier`, and
   the middleware waits for all of them. Three guarantees apply:

   - **Deterministic ordering** — results are sorted back into the original
     tool-call order before being appended, so the LLM sees a stable sequence
     regardless of which tool finished first.
   - **Errors become results** — an exception inside a tool is captured as
     `"Error: <class>: <message>"` and returned to the LLM to reason about, rather
     than crashing the pipeline (`lib/brute/middleware/070_tool_call.rb:94-100`).
   - **Universal truncation** — every result string passes through
     `Brute::Truncation.truncate` (2000-line / 50 KB cap) as a safety net so no
     single result can blow up the context window. The full output overflows to a
     temp file whose path is included in the truncated result; tools that already
     truncated internally are not double-truncated.

   Each result is appended to the session as a `role: :tool` message and emitted as
   a `:tool_result` event.

4. **Loop** (`Middleware::ToolResultLoop`,
   `lib/brute/middleware/003_tool_result_loop.rb`). The outermost loop checks the
   last message after each pass through the inner stack. If it's a `:tool` result,
   it increments `env[:current_iteration]` and re-invokes the stack so the LLM sees
   the results and continues. The loop breaks when the LLM responds with text only
   (last message is `:assistant`) or when something sets `env[:should_exit]` —
   typically `MaxIterations`.

## Summary of the flow

```
tools list (any shape)
   │  Adapter.wrap_all
   ▼
{ name => adapter } ──to_ruby_llm/to_h──▶ provider request
                                              │
                              assistant message + tool_calls
                                              │
                       ToolCall: run concurrently (Async barrier)
                       errors → result strings; truncate; sort
                                              │
                            :tool messages appended to session
                                              │
                  ToolResultLoop: last message is :tool? → loop again
                                  assistant text? → done
```
