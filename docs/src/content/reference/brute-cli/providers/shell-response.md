---
title: "BruteCLI::Providers::ShellResponse"
description: "Synthetic completion response returned by Brute::Providers::Shell."
---


```ruby
module BruteCLI::Providers
  class ShellResponse
  end
end
```

Synthetic completion response returned by Brute::Providers::Shell.

When `command` is present, the response contains a single assistant message
with a "shell" tool call. The agent loop picks it up and executes
[`Brute::Tools::Shell`](/brute/reference/brute/tools/shell/) through the
normal pipeline.

When `command` is nil (tool results round-trip), the response contains an
empty assistant message with no tool calls, causing the agent loop to exit.

## Class Methods

### self.new

```ruby
new(command: nil, model: "bash", tools: [])
```

*Not documented.*

## Instance Methods

### #choices

```ruby
choices()
```

*Not documented.*

### #content

```ruby
content()
```

*Not documented.*

### #content!

```ruby
content!()
```

*Not documented.*

### #input_tokens

```ruby
input_tokens()
```

*Not documented.*

### #messages

```ruby
messages()
```

*Not documented.*

Also aliased as: `choices`

### #model

```ruby
model()
```

*Not documented.*

### #output_tokens

```ruby
output_tokens()
```

*Not documented.*

### #reasoning_content

```ruby
reasoning_content()
```

*Not documented.*

### #reasoning_tokens

```ruby
reasoning_tokens()
```

*Not documented.*

### #total_tokens

```ruby
total_tokens()
```

*Not documented.*

### #usage

```ruby
usage()
```

*Not documented.*

## Defined in

- `lib/brute_cli/providers/shell_response.rb`
