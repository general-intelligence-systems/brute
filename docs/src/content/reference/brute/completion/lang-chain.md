---
title: "Brute::Completion::LangChain"
description: "Completion backed by the langchainrb gem (https://github.com/patterns-ai-core/langchainrb)."
---


```ruby
module Brute::Completion
  class LangChain
    include Brute::Hooks
  end
end
```

[`Completion`](/brute/reference/brute/completion/) backed by the langchainrb
gem (https://github.com/patterns-ai-core/langchainrb). Its LLM classes wrap
many providers; build one and hand it over:


```
Brute.agent
  .use(Brute::Middleware::SystemPrompt)
  .run(Brute::Completion::LangChain.new(
    llm: Langchain::LLM::OpenAI.new(api_key: ENV["OPENAI_API_KEY"]),
  ))

llm:         a Langchain::LLM instance (required; client: is an alias)
model:       model id override (falls back to env[:model], then the
             llm instance's own default)
tools:       tools list, any shape Tools::Adapter accepts
temperature: sampling temperature (default 0.7)
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
new(llm: nil, client: nil, **options)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/completion/lang_chain.rb`
