---
title: "Brute::Eval::World"
description: "The world a case wakes up in."
---


```ruby
module Brute::Eval
  class World
  end
end
```

The world a case wakes up in.

This one keeps nothing: what was said is handed straight to the turn, and the
tools answer from the case's stubs. It is what a plain agent needs, and it is
the contract a deployment's own world implements -- a world is anything that
answers:


```
#prepare(case)      lay the world out for this case, and answer what
                    the turn should be started with (nil when the
                    world delivered what was said some other way, an
                    inbox on disk say)
#stub(agent, stubs) install the case's canned tool results
#published          whatever the turn sent outward, for the record
```

Subclass to give a case somewhere to wake up:


```ruby
class Room < Brute::Eval::World
  def prepare(kase)
    super.tap { |input| inbox.append(kase.said) if input.nil? }
  end
end
```

## Attributes

### published

`published` &mdash; read-only

*Not documented.*

## Class Methods

### self.new

```ruby
new()
```

*Not documented.*

## Instance Methods

### #prepare

```ruby
prepare(kase)
```

*Not documented.*

### #stub

```ruby
stub(agent, stubs)
```

:before_tool is handed a mutable call env, and a :result set on it is answered
without the tool ever running -- so a stub replaces the web, the calendar or
the shell without the agent being built differently. A stub that answers to
#call is handed the arguments.

## Defined in

- `lib/brute/eval/world.rb`
