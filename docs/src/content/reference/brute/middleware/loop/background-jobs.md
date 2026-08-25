---
title: "Brute::Middleware::Loop::BackgroundJobs"
description: "Keeps the turn alive while background jobs are running."
---


```ruby
module Brute::Middleware::Loop
  class BackgroundJobs < Brute::Middleware::Loop
  end
end
```

Keeps the turn alive while background jobs are running. Sit it OUTSIDE the
tool loop: the inner loop ends when the model answers with text, and this one
sends control back in for another pass while jobs are still running — which is
how a finished job gets reported. Whatever spawns the jobs (say, a middleware
running a subagent in the background) keeps `env[:background_jobs]` current.


```ruby
use Brute::Middleware::Loop::BackgroundJobs
use Brute::Middleware::Loop::ToolResult
```

## Constants

### CONDITION

```ruby
CONDITION = ->(env) { env[:background_jobs] }
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(app)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/006_loop.rb`
