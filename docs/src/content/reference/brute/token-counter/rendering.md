---
title: "Brute::TokenCounter::Rendering"
description: "The text a counter measures."
---


```ruby
module Brute::TokenCounter
  module Rendering
  end
end
```

The text a counter measures.

One rendering, so two counters cannot disagree about what the conversation
even is -- and it is the same text a summariser reads, which is why it says
who spoke and what was called rather than being the shortest thing that could
be measured.

## Class Methods

### self.conversation

```ruby
conversation(messages)
```

*Not documented.*

### self.message

```ruby
message(message)
```

*Not documented.*

### self.tools

```ruby
tools(tools)
```

The schemas as the provider is given them, which is what they cost.

## Defined in

- `lib/brute/token_counter.rb`
