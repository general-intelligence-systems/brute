---
title: Tools
description: Four ways to define a tool, one neutral adapter, and a concurrent execution
  loop with automatic output truncation.
---

A tool is anything the model can invoke by name with structured arguments: read a file, run a shell command, delegate to a sub-agent. Brute accepts tools in four shapes, normalizes them through one adapter, and executes them concurrently.

## The four ways to define a tool

### 1. `Brute::Tool` subclass — how the built-ins are written

`Brute::Tool` is a tiny, dependency-free base class with a familiar description/param DSL:

```ruby
class FSRead < Brute::Tool
  description "Read the contents of a file"
  param :file_path, type: "string", desc: "Path to the file", required: true

  def name; "read"; end
  def execute(file_path:, **) = File.read(file_path)
end
```

For arguments that don't fit a flat param list, pass a raw JSON schema:

```ruby
class Question < Brute::Tool
  description "Ask the user a question"
  params({ type: "object", properties: { text: { type: "string" } }, required: %w[text] })
  def execute(text:) = ...
end
```

### 2. Inline Hash — the quickest tool

```ruby
{
  name:        "echo",
  description: "Echo the input back",
  params:      { msg: { type: "string", required: true } },
  execute:     ->(msg:) { msg },
}
```

### 3. `Brute::Turn::ToolPipeline` — when the tool needs middleware

A `ToolPipeline` runs the tool call through its own middleware stack — param validation, file-mutation queueing, snapshotting, logging:

```ruby
read = Brute::Turn::ToolPipeline.new(
  name:        "read",
  description: "Read a file's contents",
  params:      { file_path: { type: "string", required: true } },
) do
  use Brute::Middleware::Tool::ValidateParams
  run ->(env) { env[:result] = File.read(env[:arguments][:file_path]) }
end
```

### 4. `Brute::Tools::SubAgent` — an agent as a tool

A [SubAgent](../sub-agents/) exposes a tool-shaped facade so a whole agent drops into another agent's tool list.

Anything else that responds to `#name` plus `#call` or `#execute` is accepted via duck typing.

## The Adapter

`Brute::Tools::Adapter.wrap(tool)` normalizes any of the shapes above into one interface:

```ruby
adapter.name        # String
adapter.description # String
adapter.params      # { key => { type:, desc:, required: } }
adapter.call(args)  # execute with a string- or symbol-keyed Hash
adapter.to_h        # library-neutral JSON-Schema-ish definition
```

`Brute.tools(list)` (a.k.a. `Adapter.wrap_all`) turns a tool list into the `{ name_sym => adapter }` lookup the execution middleware uses. `#to_h` is what your `run` proc reshapes into each library's tool format:

```ruby
# advertise Brute's tools to the OpenAI API
def openai_tools(tools)
  Brute.tools(tools).values.map do |adapter|
    d = adapter.to_h
    { type: "function", function: { name: d[:name], description: d[:description], parameters: d[:parameters] } }
  end
end
```

Each shipped [example](../examples/) shows this conversion for its library.

## The built-in tools

`Brute::Tools::ALL` is the full coding toolset:

| Name | Class | Purpose |
|---|---|---|
| `read` | `FSRead` | Read files — line ranges, 2000-line / 50 KB caps, binary detection, directory listing |
| `write` | `FSWrite` | Create or overwrite files |
| `patch` | `FSPatch` | Find-and-replace edits |
| `remove` | `FSRemove` | Delete files/directories |
| `fs_search` | `FSSearch` | Ripgrep content search with glob filter |
| `undo` | `FSUndo` | Revert the last file mutation (via snapshots) |
| `shell` | `Shell` | Execute commands (5 min timeout, 50 KB cap, tail truncation) |
| `fetch` | `NetFetch` | HTTP GET |
| `todo_write` / `todo_read` | `TodoWrite` / `TodoRead` | Task-list scratchpad |
| `question` | `Question` | Ask the user interactive questions |
| `skill` | `SkillLoad` | Load a [skill](../skills/) on demand |

File-mutating tools share a `FileMutationQueue` (serializes writes to the same file with a fiber-aware mutex; different files proceed in parallel) and a `SnapshotStore` (records pre-mutation copies that `undo` restores).

## The execution loop

Tools are executed by the `ToolPipeline` middleware, wrapped in the tool-result loop:

```
Loop::ToolResult                 (re-invokes while the last message is a :tool result)
  └─ MaxIterations               (guard: sets env[:should_exit])
       └─ ToolPipeline           (advertises tools in; executes calls out)
            └─ run ->(env) { }   (your one LLM completion)
```

On the way in, `ToolPipeline` sets `env[:tools]`. On the way out, it collects the pending tool calls from the last assistant message and runs them, with three guarantees:

- **Concurrent execution** — each call runs as an `Async::Task` inside an `Async::Barrier` (fiber-based, via the `async` gem). Results are sorted back into call order before being appended, so the model always sees a stable sequence.
- **Errors become results** — an exception inside a tool is captured as `"Error: <class>: <message>"` and returned to the model rather than crashing the pipeline.
- **Universal truncation** — every result passes through `Brute::Truncation.truncate` (2000-line / 50 KB cap) as a safety net; the full output overflows to a temp file whose path is included. Tools that truncated internally are not double-truncated.

The `question` tool is excluded from this loop — it's handled interactively. Each result is appended as a `role: :tool` message and emitted as a `:tool_result` [event](../events/).
