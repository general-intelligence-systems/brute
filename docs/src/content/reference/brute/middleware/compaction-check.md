---
title: "Brute::Middleware::CompactionCheck"
description: "The old compaction trigger, kept working while it is deprecated."
---


```ruby
module Brute::Middleware
  class CompactionCheck < Base
    extend GemKit::Deprecate
  end
end
```

The old compaction trigger, kept working while it is deprecated.
[`DefaultCompactionPipeline`](/brute/reference/brute/middleware/default-compac
tion-pipeline/) is the layer that does the job.

It passes the turn through and compacts nothing, which is what it always did
-- and it is deliberately not a subclass of its replacement, because
inheriting would make a layer that did nothing suddenly start giving up
context. A deprecation warns about a name; it does not change what the code
under that name does.

Whatever it was configured with is accepted and ignored, so existing `use`
lines keep parsing until they are moved over:


```ruby
use Brute::Middleware::DefaultCompactionPipeline,
  window:     200_000,
  summariser: Brute::Completion::OpenRouter.new(config: { access_token: key })
```

## Class Methods

### self.new

```ruby
new(app, **_options)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/040_compaction_check.rb`
