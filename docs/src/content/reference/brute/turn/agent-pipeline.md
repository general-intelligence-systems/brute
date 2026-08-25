---
title: "Brute::Turn::AgentPipeline"
description: "agent = Brute.agent # => AgentPipeline"
---


```ruby
module Brute::Turn
  class AgentPipeline < Pipeline
  end
end
```

agent = [`Brute.agent`](/brute/reference/brute/#selfagent)            # =>
[`AgentPipeline`](/brute/reference/brute/turn/agent-pipeline/)

```
.use(Middleware::X)          # => same AgentPipeline (.use returns self)
.run ->(env) { ... }         # => same AgentPipeline (.run returns self)
```

agent.start("what changed?")   # => runs the turn, returns env

## Instance Methods

### #build

```ruby
build()
```

*Not documented.*

### #map

```ruby
map(matcher, &block)
```

Register a slash command:


```
map("/compact") { |env| ... }
map(/\Aplease compact/i) { |env| ... }
map(->(said) { said.length > 10_000 }) { |env| ... }
```

Whatever is given becomes a check: a function of what was said that answers
true or false. A String is a slash command -- "/compact" becomes ^/compact.*,
the command and whatever rides after it -- and a Regexp is wrapped in a
function that evaluates it, so by the time a command is registered there are
only functions. Anything that already answers to #call is taken as the check
itself.

This is Rack::Builder's `map` overridden: an agent routes on what was said,
not on a path, so there are no sub-builders and no URLMap.

The block is a middleware. `start` puts the registry into the turn as
`env[:commands]`, and SlashCommands -- which the builder puts at the head of
every chain -- runs the first command whose check passes on the newest
message, only when it is a user message, before the rest of the stack.

### #start

```ruby
start(input = nil, events: NullSink.new)
```

*Not documented.*

### #to_app

```ruby
to_app()
```

Every chain starts with the commands, registry or no registry: the builder
puts SlashCommands at its head rather than leaving it to a `use` someone has
to remember.

Also aliased as: `build`

## Defined in

- `lib/brute/turn/agent_pipeline.rb`
