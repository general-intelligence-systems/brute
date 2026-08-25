---
title: "Brute::Turn::Pipeline::Chainable"
description: "Module Brute::Turn::Pipeline::Chainable."
---


```ruby
module Brute::Turn::Pipeline
  module Chainable
    include Brute::Hooks
  end
end
```

## Instance Methods

### #on

```ruby
on(...)
```

Subscribe a lifecycle hook (see
[`Brute::Hooks`](/brute/reference/brute/hooks/)):


```
Brute.agent
  .use(MaxProfit)
  .run(->(env) { ... })
  .on(:before_llm) { |env| ... }
  .on(:approve_tool) { |call| call[:name] != "exec" }
```

### #run

```ruby
run(app = nil, &block)
```

*Not documented.*

### #use

```ruby
use(middleware, *args, &block)
```

Enables the following syntax:


```ruby
Brute.agent
  .use(UltraSecurity)
  .use(MaxProfit)
  .use(DontTellMom)
  .run -> (env) {
    your_llm_library.complete("How to make money?")
  }
```

Every layer announces itself: :middleware_added when it goes on the stack,
then :enter and :exit around its own work on each turn. Both of those carry
the middleware instance as self, and :exit fires from an ensure so a layer
that raises is still reported.

## Defined in

- `lib/brute/turn/pipeline.rb`
