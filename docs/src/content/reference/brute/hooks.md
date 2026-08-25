---
title: "Brute::Hooks"
description: "Pub/sub registry for agent lifecycle hooks, subscribed on the builder:"
---


```ruby
module Brute
  module Hooks
  end
end
```

Pub/sub registry for agent lifecycle hooks, subscribed on the builder:


```
Brute.agent
  .use(Brute::Middleware::MaxIterations)
  .run(->(env) { env[:messages].assistant("done") })
  .on(:before_llm) { |env| ... }
  .on(:approve_tool) { |_env, call| call[:name] != "exec" }
```

Every subscriber is called with the turn env first, followed by whatever
extras that event carries. A block that only wants the env can take one
argument and ignore the rest.

Emission points and payloads:


```
:turn_start, :turn_end  → the turn env (AgentPipeline#start; turn_end
                          fires from an ensure, so it also fires on
                          error)
:turn_duration          → env, started, finished: the turn's work is
                          this event's block
:middleware_added       → an empty env, then the middleware and every
                          argument `use` was given (fires at build time,
                          so only subscribers registered before the `use`
                          see it)
:enter                  → env, the middleware instance, before the
                          layer does anything
:duration               → env, started, finished, the middleware
                          instance: the layer's work is this event's
                          block, so it reports how long that took
:exit                   → env, the middleware instance, marking the
                          layer done (from an ensure, so it fires on
                          error too)
:before_llm, :after_llm → the turn env, around every LLM call
:llm_duration           → env, started, finished: the provider call is
                          this event's block
:llm_failure            → the turn env, when the LLM call raises; the
                          completion middleware then emits one of
                          :faraday_error, :open_router_server_error or
                          :standard_error with the exception as an extra
:compact_duration       → env, started, finished, the compactor: one
                          strategy's attempt is this event's block, so
                          the strategy that spends a model call is
                          visible, and one that declined is still timed
:compacted              → env, {strategy:, before:, after:} — a
                          compaction strategy rewrote env[:messages];
                          what it replaced is already gone, so an
                          application that keeps a transcript preserves
                          it here
:before_tool            → env, call env {name:, arguments:, result:,
                          denied:, events:, metadata:, turn_env:} —
                          mutate :arguments to rewrite the call, or set
                          :result to answer it without executing
:approve_tool           → env, call env — set :denied to true to deny
                          the call, or to a String to deny it with that
                          message
:tool_duration          → env, started, finished, call env: the tool's
                          own execution is this event's block, so a
                          skipped or denied call never fires it
:after_tool             → env, call env — mutate :result
```

Subscribers run inline (tool events may fire from parallel threads).
Exceptions propagate to the caller — layers that want fail-open semantics
rescue in their own subscriber. Include this in anything that emits or
subscribes and the event names are first class there:
[`ENTER_EVENT`](/brute/reference/brute/hooks/#enter_event) rather than
[`Brute::Hooks::ENTER_EVENT`](/brute/reference/brute/hooks/#enter_event). The
registry itself is
[`Hooks::Registry`](/brute/reference/brute/hooks/registry/), and
[`Brute::Hooks.new`](/brute/reference/brute/hooks/#selfnew) builds one.

## Constants

### AFTER_LLM_EVENT

```ruby
AFTER_LLM_EVENT = :after_llm
```

*Not documented.*

### AFTER_TOOL_EVENT

```ruby
AFTER_TOOL_EVENT = :after_tool
```

*Not documented.*

### APPROVE_TOOL_EVENT

```ruby
APPROVE_TOOL_EVENT = :approve_tool
```

*Not documented.*

### BEFORE_LLM_EVENT

```ruby
BEFORE_LLM_EVENT = :before_llm
```

*Not documented.*

### BEFORE_TOOL_EVENT

```ruby
BEFORE_TOOL_EVENT = :before_tool
```

*Not documented.*

### COMPACTED_EVENT

```ruby
COMPACTED_EVENT = :compacted
```

*Not documented.*

### COMPACT_DURATION_EVENT

```ruby
COMPACT_DURATION_EVENT = :compact_duration
```

*Not documented.*

### DURATION_EVENT

```ruby
DURATION_EVENT = :duration
```

*Not documented.*

### ENTER_EVENT

```ruby
ENTER_EVENT = :enter
```

*Not documented.*

### EXIT_EVENT

```ruby
EXIT_EVENT = :exit
```

*Not documented.*

### FARADAY_ERROR_EVENT

```ruby
FARADAY_ERROR_EVENT = :faraday_error
```

*Not documented.*

### LLM_DURATION_EVENT

```ruby
LLM_DURATION_EVENT = :llm_duration
```

*Not documented.*

### LLM_FAILURE_EVENT

```ruby
LLM_FAILURE_EVENT = :llm_failure
```

*Not documented.*

### MIDDLEWARE_ADDED_EVENT

```ruby
MIDDLEWARE_ADDED_EVENT = :middleware_added
```

*Not documented.*

### OPEN_ROUTER_SERVER_ERROR_EVENT

```ruby
OPEN_ROUTER_SERVER_ERROR_EVENT = :open_router_server_error
```

*Not documented.*

### STANDARD_ERROR_EVENT

```ruby
STANDARD_ERROR_EVENT = :standard_error
```

*Not documented.*

### TOOL_DURATION_EVENT

```ruby
TOOL_DURATION_EVENT = :tool_duration
```

*Not documented.*

### TURN_DURATION_EVENT

```ruby
TURN_DURATION_EVENT = :turn_duration
```

*Not documented.*

### TURN_END_EVENT

```ruby
TURN_END_EVENT = :turn_end
```

*Not documented.*

### TURN_START_EVENT

```ruby
TURN_START_EVENT = :turn_start
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(...)
```

*Not documented.*

## Defined in

- `lib/brute/hooks.rb`
