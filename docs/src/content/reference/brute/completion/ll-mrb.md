---
title: "Brute::Completion::LLMrb"
description: "Completion backed by the llm.rb gem (https://github.com/llmrb/llm.rb)."
---


```ruby
module Brute::Completion
  class LLMrb
    include Brute::Hooks
  end
end
```

[`Completion`](/brute/reference/brute/completion/) backed by the llm.rb gem
(https://github.com/llmrb/llm.rb).


```
Brute.agent
  .use(Brute::Middleware::SystemPrompt)
  .run(Brute::Completion::LLMrb.new(
    provider:         :openai,
    provider_options: { key: ENV["OPENAI_API_KEY"] },
    model:            "gpt-4o-mini",
  ))

# or hand over a provider llm.rb has already built:
run Brute::Completion::LLMrb.new(client: LLM.ollama(key: nil), model: "llama3.2:latest")

client:           an LLM::Provider instance (takes precedence)
provider:         llm.rb constructor name (:openai, :anthropic,
                  :ollama, ...); falls back to env[:provider]
provider_options: kwargs for that constructor, e.g. { key: "..." }
model:            model id (falls back to env[:model])
tools:            tools list, any shape Tools::Adapter accepts
temperature:      sampling temperature (default 0.7)
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

- `lib/brute/completion/llmrb.rb`
