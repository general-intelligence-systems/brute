---
title: "BruteCLI::Providers::Shell"
description: "A pseudo-LLM provider that executes user input as code via the existing Brute::Tools::Shell tool."
---


```ruby
module BruteCLI::Providers
  class Shell
  end
end
```

A pseudo-LLM provider that executes user input as code via the existing
[`Brute::Tools::Shell`](/brute/reference/brute/tools/shell/) tool.

Models correspond to interpreters:


```
bash   - pass-through (default)
ruby   - ruby -e '...'
python - python3 -c '...'
nix    - nix eval --expr '...'
```

The provider's
[`#complete`](/brute/reference/brute-cli/providers/shell/#complete) method
returns a synthetic response containing a single "shell" tool call. The agent
loop executes it through the normal pipeline — all middleware (message
tracking, session persistence, token tracking, etc.) fires as usual.

## Constants

### INTERPRETERS

```ruby
INTERPRETERS = {
        "bash"   => ->(cmd) { cmd },
        "ruby"   => ->(cmd) { "ruby -e #{Shellwords.escape(cmd)}" },
        "python" => ->(cmd) { "python3 -c #{Shellwords.escape(cmd)}" },
        "nix"    => ->(cmd) { "nix eval --expr #{Shellwords.escape(cmd)}" },
      }.freeze
```

*Not documented.*

### MODELS

```ruby
MODELS = %w[bash ruby python nix].freeze
```

*Not documented.*

## Instance Methods

### #complete

```ruby
complete(prompt, params = {})
```

*Not documented.*

### #default_model

```ruby
default_model()
```

*Not documented.*

### #models

```ruby
models()
```

For the REPL model picker: provider.models.all.select(&:chat?)

### #name

```ruby
name()
```

── Provider interface ─────────────────────────────────────────

## Defined in

- `lib/brute_cli/providers/shell.rb`
