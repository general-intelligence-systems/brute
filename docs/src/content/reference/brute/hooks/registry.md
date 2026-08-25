---
title: "Brute::Hooks::Registry"
description: "The pub/sub registry a pipeline owns; use and run bind an emit to it."
---


```ruby
module Brute::Hooks
  class Registry
  end
end
```

The pub/sub registry a pipeline owns; `use` and `run` bind an emit to it.

## Class Methods

### self.new

```ruby
new()
```

*Not documented.*

## Instance Methods

### #any?

```ruby
any?(event)
```

*Not documented.*

### #emit

```ruby
emit(event, env, *extras, &block)
```

Fire an event. An emitter announces; it answers nothing, and what a
subscriber's block happens to evaluate to is not a signal. A layer that wants
to take part in a turn does it by mutating what it was handed, never by
returning something.

Given a block, the event is timed instead: the block is the work, and
subscribers fire once it is done, called as `|env, started, finished,
*extras|` rather than `|env, *extras|`. Both stamps are monotonic, so a clock
adjustment mid-turn cannot produce a negative duration.

The block is the work and nothing more: `emit` answers nothing in either form,
so a caller that needs the work's value takes it inside the block.


```ruby
result = nil
emit(DURATION_EVENT, env, self) { result = @app.call(env) }
# => .on(DURATION_EVENT) { |env, started, finished, layer| ... }
```

Subscribers fire from an ensure, so work that raises is still timed and still
reported before the exception carries on up.

### #on

```ruby
on(event, &block)
```

*Not documented.*

## Defined in

- `lib/brute/hooks.rb`
