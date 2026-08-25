---
title: "BruteCLI::Providers::Shell::ModelList"
description: "Minimal object that quacks like provider.models so the REPL's fetch_models can call provider.models.all.select(&:chat?)."
---


```ruby
module BruteCLI::Providers::Shell
  class ModelList
  end
end
```

Minimal object that quacks like provider.models so the REPL's fetch_models can
call provider.models.all.select(&:chat?).

## Constants

### ModelEntry

```ruby
ModelEntry = Struct.new(:id, :chat?, keyword_init: true)
```

*Not documented.*

## Class Methods

### self.new

```ruby
new(names)
```

*Not documented.*

## Instance Methods

### #all

```ruby
all()
```

*Not documented.*

## Defined in

- `lib/brute_cli/providers/shell.rb`
