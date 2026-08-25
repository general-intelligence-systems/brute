---
title: "Brute::TokenCounter::Tiktoken"
description: "Tokens from OpenAI's byte-pair encoder, through the tiktoken_ruby gem."
---


```ruby
module Brute::TokenCounter
  class Tiktoken
  end
end
```

Tokens from OpenAI's byte-pair encoder, through the tiktoken_ruby gem.


```ruby
gem "tiktoken_ruby"
use Brute::Middleware::DefaultCompactionPipeline,
  window:        200_000,
  token_counter: Brute::TokenCounter::Tiktoken.new
```

[`Brute`](/brute/reference/brute/) depends on no LLM library, and this is no
exception: the gem is required the first time the counter is asked for a
number, so an agent that never installs it never pays for it and never hears
about it.

It is exact about the text and still approximate about the request --
`per_message` stands in for the chat-template framing, which is the provider's
and not in any encoder.

## Constants

### ENCODING

```ruby
ENCODING = "o200k_base"
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(encoding: ENCODING, per_message: 4, encoder: nil)
```

*Not documented.*

## Instance Methods

### #count

```ruby
count(messages, tools: nil)
```

*Not documented.*

### #warm_up

```ruby
warm_up()
```

Load the encoder, downloading its vocabulary if it is not cached yet.

## Defined in

- `lib/brute/token_counter/tiktoken.rb`
