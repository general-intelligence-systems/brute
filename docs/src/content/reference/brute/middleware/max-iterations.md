---
title: "Brute::Middleware::MaxIterations"
description: "Guards against runaway tool loops by capping the number of iterations."
---


```ruby
module Brute::Middleware
  class MaxIterations < Base
  end
end
```

Guards against runaway tool loops by capping the number of iterations.

When the limit is reached, injects a user message into the session stating
that maximum iterations have been reached. This causes
[`Loop::ToolResult`](/brute/reference/brute/middleware/loop/tool-result/) to
exit its loop naturally (last message is not :tool).

## Constants

### DEFAULT_MAX_ITERATIONS

```ruby
DEFAULT_MAX_ITERATIONS = 100
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(app, max_iterations: DEFAULT_MAX_ITERATIONS)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/010_max_iterations.rb`
