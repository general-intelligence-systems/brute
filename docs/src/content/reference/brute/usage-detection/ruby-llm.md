---
title: "Brute::UsageDetection::RubyLLM"
description: "ruby_llm hangs usage off the message, not the response: a Tokens object with input/output/cache_read/cache_write/thinking, plus the provider's own reported_c..."
---


```ruby
module Brute::UsageDetection
  module RubyLLM
  end
end
```

ruby_llm hangs usage off the **message**, not the response: a Tokens object
with input/output/cache_read/cache_write/thinking, plus the provider's own
reported_cost when it gives one.

## Class Methods

### self.detect

```ruby
detect(message)
```

*Not documented.*

### self.read

```ruby
read(tokens, name)
```

*Not documented.*

## Defined in

- `lib/brute/usage_detection/ruby_llm.rb`
