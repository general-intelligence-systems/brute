---
title: "Brute::Middleware::Base"
description: "The parent of every middleware: it takes the next app, does its work around it, and calls it."
---


```ruby
module Brute::Middleware
  class Base
    include Brute::Hooks
  end
end
```

The parent of every middleware: it takes the next app, does its work around
it, and calls it.


```ruby
class Shout < Brute::Middleware::Base
  def call(env)
    emit(ENTER_EVENT, env, self)
    @app.call(env)
  end
end
```

[`Brute::Hooks`](/brute/reference/brute/hooks/) is included, so the event
names are first class in every subclass — ENTER_EVENT, not
[`Brute::Hooks::ENTER_EVENT`](/brute/reference/brute/hooks/#enter_event).

## Class Methods

### self.new

```ruby
new(app, *, **)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

A layer that adds nothing passes the turn straight through.

## Defined in

- `lib/brute/middleware/000_base.rb`
