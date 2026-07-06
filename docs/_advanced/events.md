---
layout: default
title: Events
nav_order: 4
description: 'A stackable event sink on env[:events] streams progress — content, tool calls, results, errors — to terminal output or any handler you write.'
---

# Events

While a turn runs, middleware and tools push events to `env[:events]` — a sink you can stack handlers onto for live progress. By default it's a null sink that swallows everything; add the `EventHandler` middleware to route events somewhere.

## Turning it on

```ruby
Brute.agent
  .use(Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput)
  # ... rest of the stack ...
```

`EventHandler` wraps `env[:events]` in your handler class on the way in, so everything downstream streams through it.

## The events

Events are `{ type:, data: }` hashes. The common types:

| Type | Emitted when | `data` |
|---|---|---|
| `:content` | assistant text streams/arrives | the text |
| `:reasoning` | thinking/reasoning text | the text |
| `:tool_call_start` | the model calls tools | array of `{ name, call_id, arguments }` |
| `:tool_result` | a tool finishes | `{ name, content }` |
| `:error` | a tool raises | `{ error, message }` |

## Writing a handler

Handlers are stackable: subclass `Brute::Events::Handler`, override `<<`, do your thing, then call `super` to pass the event down the stack (or don't, to swallow it). `Brute::Events::TerminalOutput` dispatches each event to an `on_<type>` method:

```ruby
class MyHandler < Brute::Events::Handler
  def <<(event)
    case event.to_h[:type]
    when :tool_call_start
      event.to_h[:data].each { |tc| warn "→ #{tc[:name]} #{tc[:arguments]}" }
    when :content
      print event.to_h[:data]
    end
    super   # pass down to the inner handler
  end
end

Brute.agent.use(Brute::Middleware::EventHandler, handler_class: MyHandler)
```

Because handlers stack, you can layer several — say, terminal output plus a JSONL logger — by nesting `EventHandler` middleware. Each wraps the sink the previous one installed.

## Terminal output

`Brute::Events::TerminalOutput` is the batteries-included handler used by the examples: it streams assistant content to stdout, prints `[tool] name - args` when tools start and `[tool] name - done` when they finish, indents reasoning to stderr, and formats errors. It's a good template to copy for a custom UI.
