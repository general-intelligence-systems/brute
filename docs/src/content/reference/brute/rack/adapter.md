---
title: "Brute::Rack::Adapter"
description: "Class Brute::Rack::Adapter."
---


```ruby
module Brute::Rack
  class Adapter
  end
end
```

## Constants

### PROMPT_KEYS

```ruby
PROMPT_KEYS = %w[prompt message input].freeze
```

Body/JSON keys we accept a prompt under, in priority order. `prompt` is
canonical; `message`/`input` are common aliases.

## Class Methods

### self.for

```ruby
for(agent)
```

Convenience factory so the config.ru reads `run
[`Adapter.for(agent)`](/brute/reference/brute/rack/adapter/#selffor)`.

### self.new

```ruby
new(agent)
```

@parameter agent [#start] Anything with `start(prompt) -> env` — an

```
AgentPipeline, a SubAgent, or any turn-shaped callable.
```

## Instance Methods

### #call

```ruby
call(env)
```

[`Rack`](/brute/reference/brute/rack/) entry point. Extract the prompt, run
one agent turn, render the assistant's reply back as an HTTP response. A
missing prompt is a 400 (client's fault); anything the turn raises is a 500.

### #prompt_from

```ruby
prompt_from(env)
```

env -> prompt string. Four ways in, most explicit first:


```
1. a `?prompt=` query param (never touches the body),
2. a JSON body — a known key of an object, or a bare JSON string,
3. a form-encoded `prompt=` field,
4. otherwise the raw request body IS the prompt.
```

Returns nil when nothing usable is present.

### #response_for

```ruby
response_for(env, status, output)
```

output -> [status, headers, body]. Content-negotiated: JSON in (or an `Accept:
application/json`) gets `{"response": "..."}` back; everything else gets
<code>text/plain</code>. Errors ride the same path so a 500 body is shaped
like a 200 body.

## Defined in

- `lib/brute/rack/adapter.rb`
