---
title: "Brute::UsageDetection::LangChain"
description: "langchainrb has no single usage object: each provider's response subclass answers prompt_tokens / completion_tokens / total_tokens by digging its own raw sha..."
---


```ruby
module Brute::UsageDetection
  module LangChain
  end
end
```

langchainrb has no single usage object: each provider's response subclass
answers prompt_tokens / completion_tokens / total_tokens by digging its own
raw shape, and some answer none of them.

## Class Methods

### self.detect

```ruby
detect(response)
```

*Not documented.*

### self.read

```ruby
read(response, name)
```

*Not documented.*

## Defined in

- `lib/brute/usage_detection/lang_chain.rb`
