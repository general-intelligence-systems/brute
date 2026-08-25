---
title: "Brute::Contrib::Otel"
description: "OpenTelemetry for a turn, as hooks rather than middleware."
---


```ruby
module Brute::Contrib
  module Otel
  end
end
```

OpenTelemetry for a turn, as hooks rather than middleware.


```ruby
Brute::Contrib::Otel.subscribe(agent)
agent.start("what changed?")
```

These are pure observers: they read the turn and write spans, and never touch
what the agent does. That is why they are subscribers and not layers — a
middleware earns its place in the stack by being able to alter or skip what is
below it, and telemetry never should.

Every event it needs already exists:


```
turn_start / turn_end   the span itself
after_llm               token usage, from env[:metadata][:last_llm_usage]
before_tool / after_tool a span event per tool call and result
```

The tracer is injectable; without one it asks OpenTelemetry, and when the SDK
is not loaded `subscribe` does nothing at all.

Note the span is opened and finished by hand rather than through
<code>tracer.in_span</code>, which wants a block around the work.
OpenTelemetry's current context is fiber-local, so this does not attach the
span as current: under Async a turn's LLM call and its tools may run in other
fibers, and an attached-but-never-detached context leaks across them.

## Constants

### SPAN_NAME

```ruby
SPAN_NAME = "brute.turn"
```

*Not documented.*

## Class Methods

### self.default_tracer

```ruby
default_tracer()
```

*Not documented.*

### self.subscribe

```ruby
subscribe(agent, tracer: default_tracer)
```

*Not documented.*

## Defined in

- `lib/brute/contrib/otel.rb`
