---
title: "Brute::Middleware::UserQueue"
description: "Class Brute::Middleware::UserQueue."
---


```ruby
module Brute::Middleware
  class UserQueue < Base
  end
end
```

## Class Methods

### self.new

```ruby
new(app, inputs: [])
```

Useful for testing... App will keep looping till all inputs are drained.

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/user_queue.rb`
