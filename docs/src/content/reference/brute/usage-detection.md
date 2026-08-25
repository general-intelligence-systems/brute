---
title: "Brute::UsageDetection"
description: "What the provider reported, normalised."
---


```ruby
module Brute
  module UsageDetection
  end
end
```

What the provider reported, normalised. Every library reports usage
differently —OpenRouter as a raw hash on the response, ruby_llm as a Tokens
object on the **message**, llm.rb as an LLM::Usage, langchainrb as
per-provider methods digging their own raw shape — so each strategy here reads
one of them and answers the same
[`Usage`](/brute/reference/brute/usage-detection/#usage).


```ruby
Brute::UsageDetection::OpenRouter.detect(response)
# => #<data Brute::UsageDetection::Usage input=10, output=5, total=15, ...>
```

A strategy reads one response and answers what that provider said —nothing
more. It does not derive, sum or accumulate: running totals for a turn are the
env's business, not the reader's. A strategy answers nil when the provider
reported nothing at all.

## Constants

### Usage

```ruby
Usage = Data.define(:input, :output, :total, :reasoning, :cache_read, :cache_write, :cost, :raw) do
      def initialize(input: nil, output: nil, total: nil, reasoning: nil,
                     cache_read: nil, cache_write: nil, cost: nil, raw: nil)
        super
      end

      # What a provider did not report stays out, so a reader sees the counts
      # that are real rather than a row of nils.
      def to_h = super.compact

      def empty? = [input, output, total].all?(&:nil?)
    end
```

*Not documented.*

## Defined in

- `lib/brute/usage_detection/lang_chain.rb`
- `lib/brute/usage_detection/llmrb.rb`
- `lib/brute/usage_detection/open_router.rb`
- `lib/brute/usage_detection/ruby_llm.rb`
- `lib/brute/usage_detection/usage.rb`
