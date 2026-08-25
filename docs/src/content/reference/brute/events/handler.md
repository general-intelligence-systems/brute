---
title: "Brute::Events::Handler"
description: "Stackable event handler base class."
---


```ruby
module Brute::Events
  class Handler
  end
end
```

Stackable event handler base class. Subclasses override the append method, do
their thing, then call super (or don't, to swallow the event).

## Class Methods

### self.new

```ruby
new(inner)
```

*Not documented.*

## Instance Methods

### #<<

```ruby
<<(event)
```

Default: pass through. Subclasses override this method, do their thing, then
call super (or don't, to swallow the event).

## Defined in

- `lib/brute/events/handler.rb`
