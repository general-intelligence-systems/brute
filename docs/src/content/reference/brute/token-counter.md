---
title: "Brute::TokenCounter"
description: "How big a conversation is, in tokens."
---


```ruby
module Brute
  module TokenCounter
  end
end
```

How big a conversation is, in tokens.

A counter is anything answering `count(messages, tools: nil)`. The tools are
part of the question because their schemas ride in every request alongside the
messages -- an agent carrying a dozen of them is spending context on JSON
Schema before anyone has said a word.


```ruby
counter = Brute::TokenCounter::Approximate.new
counter.count(env[:messages], tools: env[:tools])
```

What a turn is **currently** costing is a different question, and `estimate`
answers it: the provider counted the conversation exactly when it answered, so
that number is trusted and only what has been appended since is counted
locally.


```ruby
Brute::TokenCounter.estimate(env)
```

## Class Methods

### self.default

```ruby
default()
```

*Not documented.*

### self.estimate

```ruby
estimate(env, counter: nil, tools: nil)
```

What the whole turn costs right now.

:counter defaults to the one the turn already decided on
(`env[:token_counter]`), :tools to the ones the pipeline advertises
(`env[:tools]`).

The reported total already covers the system prompt, the tool schemas and the
provider's own chat-template overhead, so the warm path adds only the messages
that landed after the reply it describes -- and never the schemas, which are
already inside it. Anything else double counts.

## Defined in

- `lib/brute/token_counter.rb`
- `lib/brute/token_counter/approximate.rb`
- `lib/brute/token_counter/tiktoken.rb`
