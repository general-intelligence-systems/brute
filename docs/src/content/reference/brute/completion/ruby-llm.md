---
title: "Brute::Completion::RubyLLM"
description: "Completion backed by the ruby_llm gem."
---


```ruby
module Brute::Completion
  class RubyLLM
    include Brute::Hooks
  end
end
```

[`Completion`](/brute/reference/brute/completion/) backed by the ruby_llm gem.


```ruby
Brute.agent
  .use(Brute::Middleware::SystemPrompt)
  .run(Brute::Completion::RubyLLM.new(provider: :ollama, model: "llama3.2:latest"))
```

Anything not given at point of use falls back to env, so a pipeline that sets
`env[:provider]` / `env[:model]` still flows through.


```
provider:    LLM provider name (falls back to env[:provider])
model:       model id (falls back to env[:model])
tools:       tools list, any shape Tools::Adapter accepts
temperature: sampling temperature (default 0.7)
streaming:   stream chunks as :content / :reasoning events
client:      injectable completion client (tests, custom transports);
             anything responding to complete(messages, **kwargs)
```

## Constants

### DEFAULT_TEMPERATURE

```ruby
DEFAULT_TEMPERATURE = 0.7
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(**options)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/completion/ruby_llm.rb`
