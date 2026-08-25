---
title: "Brute::Middleware::SlashCommands"
description: "The head of every agent chain, put there by the builder itself rather than by a use anyone writes."
---


```ruby
module Brute::Middleware
  class SlashCommands < Base
  end
end
```

The head of every agent chain, put there by the builder itself rather than by
a `use` anyone writes. It switches on what was just said: the newest message,
and only when it is a user message, is offered to each of `env[:commands]`'s
checks in turn -- the commands registered with `AgentPipeline#map`, which
`start` puts there. The first check that passes has its block run here, before
the rest of the stack.


```
Brute.agent
  .map("/compact") { |env| ... }
  .run(->(env) { ... })
```

A command's block is a middleware, so what it leaves in env is what the rest
of the chain works on.

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/001_slash_commands.rb`
