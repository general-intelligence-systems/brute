---
title: "Brute::UsageDetection::LLMrb"
description: "llm.rb models usage as its own LLM::Usage value object."
---


```ruby
module Brute::UsageDetection
  module LLMrb
  end
end
```

llm.rb models usage as its own LLM::Usage value object. Note it answers 0, not
nil, for anything the provider left out — that is llm.rb's reading of the
response and it is reported as given.

## Class Methods

### self.detect

```ruby
detect(response)
```

*Not documented.*

### self.read

```ruby
read(usage, name)
```

*Not documented.*

## Defined in

- `lib/brute/usage_detection/llmrb.rb`
