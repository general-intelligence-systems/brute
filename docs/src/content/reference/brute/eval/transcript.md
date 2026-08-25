---
title: "Brute::Eval::Transcript"
description: "What one turn did."
---


```ruby
module Brute::Eval
  class Transcript
  end
end
```

What one turn did.

Every observation comes off the agent's own hooks, so a transcript is what the
run itself reported: the tool calls in the order they were made, with the
result each came back with, what the model finally said, what the provider
charged for it, and how the call failed when it did. Nothing in the agent
knows it is being watched.


```ruby
transcript = Brute::Eval::Transcript.new
transcript.subscribe(agent)
agent.start("what changed?")

transcript.called?("search", "query" => /fed/i)
transcript.before?("read", "write")
```

## Attributes

### calls

`calls` &mdash; read-only

*Not documented.*

### error

`error` &mdash; read/write

*Not documented.*

### failures

`failures` &mdash; read-only

*Not documented.*

### published

`published` &mdash; read/write

*Not documented.*

### seconds

`seconds` &mdash; read/write

*Not documented.*

### usage

`usage` &mdash; read-only

*Not documented.*

## Class Methods

### self.new

```ruby
new()
```

*Not documented.*

## Instance Methods

### #before?

```ruby
before?(first, second)
```

*Not documented.*

### #called?

```ruby
called?(name, arguments = {})
```

A call the turn made, matched on name and on whatever arguments the case cares
about -- `===`, so a case says `"query" => /fed/i` as readily as `"count" =>
3`.

### #counts

```ruby
counts()
```

*Not documented.*

### #errors

```ruby
errors()
```

*Not documented.*

### #iterations

```ruby
iterations()
```

*Not documented.*

### #names

```ruby
names()
```

*Not documented.*

### #reply

```ruby
reply()
```

*Not documented.*

### #subscribe

```ruby
subscribe(agent)
```

The call env the tool pipeline hands its subscribers is one mutable hash per
call, so the entry kept here at :before_tool carries the result the tool
answered with by the time anyone reads it.

### #tokens

```ruby
tokens()
```

*Not documented.*

## Defined in

- `lib/brute/eval/transcript.rb`
