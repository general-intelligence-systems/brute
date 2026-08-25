---
title: Messages
description: The conversation log is a plain Array of Brute::Message — an immutable
  Data value that any LLM library can be translated to and from.
sidebar:
  order: 2
---

Brute's conversation log is a plain `Array`. Each entry is a `Brute::Message` — an immutable [`Data`](https://docs.ruby-lang.org/en/master/Data.html) value that is Brute's canonical, framework-agnostic message format.

```ruby
Brute::Message = Data.define(:role, :content, :tool_calls, :tool_call_id)
```

| Field | Type | Notes |
|---|---|---|
| `role` | Symbol | `:user`, `:assistant`, `:system`, or `:tool` (string roles are symbolized) |
| `content` | String | the text; may be `""` on a tool-call assistant turn |
| `tool_calls` | Array of `Brute::ToolCall` or nil | assistant turns that call tools |
| `tool_call_id` | String or nil | links a `:tool` result back to its call |

```ruby
Brute::ToolCall = Data.define(:id, :name, :arguments)   # arguments is always a Hash
```

## Building a log

`Brute.log` returns an Array extended with role-tagging sugar (the `Brute::Messages` module):

```ruby
log = Brute.log
log.user("list the files")
log.assistant("")            # ... with tool calls, usually
log.tool("a.rb b.rb", tool_call_id: "tc1")

log.first.role       # => :user
log.first.content    # => "list the files"
```

You can also build messages directly:

```ruby
Brute::Message.new(role: :user, content: "hi")

Brute::Message.new(role: :assistant, content: "", tool_calls: [
  Brute::ToolCall.new(id: "tc1", name: "shell", arguments: { "command" => "ls" }),
])

Brute::Message.new(role: :tool, content: "result", tool_call_id: "tc1")
```

`tool_calls` accepts hashes and coerces them into `ToolCall`, so a message rebuilt from parsed JSON just works:

```ruby
Brute::Message.new(**JSON.parse(line, symbolize_names: true))
```

## Helpers

```ruby
message.tool_call?   # => true when tool_calls is present and non-empty
message.to_h         # plain Hash, nils dropped, tool calls as hashes — JSON-ready
```

`to_h` round-trips: `Brute::Message.new(**m.to_h) == m`. This is exactly what [`SessionLog`](../sessions/) writes to and reads from disk.

## Duck typing

Nothing in Brute's stack calls anything beyond `#role`, `#content`, `#tool_calls`, `#tool_call_id`, and `#to_h`. `Brute::Message` is the canonical implementation, but any object exposing those methods can ride in `env[:messages]`. That is the seam that keeps Brute framework-agnostic — and the reason a library's own message objects can pass straight through if you'd rather not convert them.

The conversion between `Brute::Message` and a specific LLM library's format is handled by a [MessageTransport](../message-transports/).
