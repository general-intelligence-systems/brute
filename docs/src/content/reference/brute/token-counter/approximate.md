---
title: "Brute::TokenCounter::Approximate"
description: "Tokens from text length, at a flat ratio of characters to tokens."
---


```ruby
module Brute::TokenCounter
  class Approximate
  end
end
```

Tokens from text length, at a flat ratio of characters to tokens.

Four characters to the token is the usual approximation. It needs no
dependency and it is close enough to decide what to give up; put a
[`Tiktoken`](/brute/reference/brute/token-counter/tiktoken/) counter on
`env[:token_counter]` when the difference matters.

`per_message` is what the rendering cannot see: every message is wrapped in
the provider's own chat template on the way out, and that framing costs a few
tokens each whatever the message says.

## Class Methods

### self.new

```ruby
new(chars_per_token: 4.0, per_message: 4)
```

*Not documented.*

## Instance Methods

### #count

```ruby
count(messages, tools: nil)
```

*Not documented.*

## Defined in

- `lib/brute/token_counter/approximate.rb`
