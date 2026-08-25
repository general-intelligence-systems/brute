---
title: "Brute::Middleware::Loop"
description: "Re-invokes the inner stack as long as a condition holds — a generic loop over a turn."
---


```ruby
module Brute::Middleware
  class Loop < Base
  end
end
```

Re-invokes the inner stack as long as a condition holds — a generic loop over
a turn. The condition is a proc or block that receives env and returns truthy
to send control back down the chain again, falsy to stop.

The inner app always runs at least once; the condition is checked after each
pass (do-while).


```sh
# loop while the last message is a tool result (see Loop::ToolResult):
use Brute::Middleware::Loop, ->(env) { env[:messages].last&.role == :tool }

# block form — e.g. bump an iteration counter and stop on should_exit:
use Brute::Middleware::Loop do |env|
  env[:current_iteration] += 1
  !env[:should_exit] && env[:messages].last&.role == :tool
end
```

## Class Methods

### self.new

```ruby
new(app, condition = nil, &block)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/006_loop.rb`
