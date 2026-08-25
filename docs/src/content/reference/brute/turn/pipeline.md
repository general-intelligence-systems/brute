---
title: "Brute::Turn::Pipeline"
description: "Class Brute::Turn::Pipeline."
---


```ruby
module Brute::Turn
  class Pipeline < Rack::Builder
    include Pipeline::Chainable
  end
end
```

## Class Methods

### self.new_from_string

```ruby
new_from_string(builder_script, path = "(rackup)", **options)
```

Rack's `new_from_string` evaluates the script then returns `to_app` —the built
callable. An agent, though, is the **builder**: you <code>.start</code> it,
and it may be re-`use`d or served through the
[`Rack`](/brute/reference/brute/rack/) adapter. So evaluate the script against
a fresh builder and hand back the builder itself. This also backs `parse_file`
(→ `load_file` → here), so
`AgentPipeline.parse_file("agent.ru").start(prompt)` works as documented.

## Instance Methods

### #hooks

```ruby
hooks()
```

The lifecycle-hook registry for this pipeline (see
[`Brute::Hooks`](/brute/reference/brute/hooks/)).

## Defined in

- `lib/brute/turn/pipeline.rb`
