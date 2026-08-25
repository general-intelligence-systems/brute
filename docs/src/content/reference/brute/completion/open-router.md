---
title: "Brute::Completion::OpenRouter"
description: "Class Brute::Completion::OpenRouter."
---


```ruby
module Brute::Completion
  class OpenRouter
    include Brute::Hooks
  end
end
```

## Class Methods

### self.new

```ruby
new(config: {}, **options)
```

Anything not given here falls back to the turn env, the way the other
completions do it: tools from `env[:tools]` — the list the ToolPipeline
middleware puts there and executes, so a pipeline declares its tools once —
and the model from `env[:model]`, which lets a middleware route a turn to a
different one. Options given at point of use always win.

config:   keyword arguments for OpenRouter::Client.new

```
(access_token:, request_timeout:, uri_base:, extra_headers:).
Defaults to OpenRouter.configuration's global settings.
```

options:  keyword arguments for OpenRouter::CompletionOptions.new

```
(model:, temperature:, tools:, ...).
```

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/completion/open_router.rb`
