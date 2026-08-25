---
title: "Brute::Completion"
description: "Completion middlewares — the terminal step of an agent turn."
---


```ruby
module Brute
  module Completion
  end
end
```

[`Completion`](/brute/reference/brute/completion/) middlewares — the terminal
step of an agent turn. Each one is a ready-made replacement for the
hand-written `run` proc: it takes `env[:messages]`, calls one provider, and
appends the reply back onto the log.


```ruby
Brute.agent
  .use(Brute::Middleware::SystemPrompt)
  .run(Brute::Completion::OpenRouter.new(model: "anthropic/claude-sonnet-4"))
```

[`Brute`](/brute/reference/brute/) still owns no LLM library: each class here
requires only the gem for its own provider, and only when you use it.

## Defined in

- `lib/brute/completion/lang_chain.rb`
- `lib/brute/completion/llmrb.rb`
- `lib/brute/completion/open_router.rb`
- `lib/brute/completion/ruby_llm.rb`
