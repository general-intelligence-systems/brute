---
title: "Brute::Prompts::Context"
description: "Template context handed to ERB templates."
---


```ruby
module Brute::Prompts
  class Context
  end
end
```

Template context handed to ERB templates. Context-hash keys become methods
(<%= skills %>, <%= cwd %>), plus view helpers like `h`.

## Class Methods

### self.new

```ruby
new(ctx)
```

*Not documented.*

## Instance Methods

### #escape_xml

```ruby
escape_xml(value)
```

XML-escape a value for prompt markup (& < > " ').

Also aliased as: `h`

### #get_binding

```ruby
get_binding()
```

*Not documented.*

### #h

```ruby
h(value)
```

*Not documented.*

### #method_missing

```ruby
method_missing(name, *args)
```

*Not documented.*

### #respond_to_missing?

```ruby
respond_to_missing?(name, include_private = false)
```

*Not documented.*

## Defined in

- `lib/brute/prompts/base.rb`
