---
title: "Brute::UsageDetection::OpenRouter"
description: "OpenRouter reports usage as the provider's raw hash on the response, in OpenAI's wire shape."
---


```ruby
module Brute::UsageDetection
  module OpenRouter
  end
end
```

[`OpenRouter`](/brute/reference/brute/usage-detection/open-router/) reports
usage as the provider's raw hash on the response, in OpenAI's wire shape.
Reasoning tokens, when the model reports them, arrive nested under
completion_tokens_details.

## Class Methods

### self.detect

```ruby
detect(response)
```

*Not documented.*

### self.field

```ruby
field(hash, key)
```

[`OpenRouter`](/brute/reference/brute/usage-detection/open-router/) hands back
string keys; a hand-built response may not.

## Defined in

- `lib/brute/usage_detection/open_router.rb`
