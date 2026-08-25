---
title: "Brute::Env"
description: "What the turn came back with, asked of the env itself."
---


```ruby
module Brute
  module Env
  end
end
```

What the turn came back with, asked of the env itself.


```ruby
env = agent.start("hello")
env.extend(Brute::Env)
env.reply.content if env.has_reply?
```

A turn ends with whatever the last middleware left in `env[:messages]`, and
that is not always an answer: a turn that only ran tools, or that the provider
failed, ends on something else. So the reply is the last message AND only when
the assistant is the one who wrote it.

## Instance Methods

### #has_reply?

```ruby
has_reply?()
```

*Not documented.*

### #reply

```ruby
reply()
```

*Not documented.*

## Defined in

- `lib/brute/env.rb`
