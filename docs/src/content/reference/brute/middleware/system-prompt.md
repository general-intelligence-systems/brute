---
title: "Brute::Middleware::SystemPrompt"
description: "Prepends a system message to env[:messages] before passing control down the middleware chain."
---


```ruby
module Brute::Middleware
  class SystemPrompt < Base
  end
end
```

Prepends a system message to `env[:messages]` before passing control down the
middleware chain.

By default, uses
[`Brute::SystemPrompt.default`](/brute/reference/brute/system-prompt/#selfdefa
ult) which assembles a provider-specific prompt stack (Identity, ToneAndStyle,
ToolUsage, etc.) from the [`Brute::Prompts`](/brute/reference/brute/prompts/)
modules and text files.

Pass a custom [`Brute::SystemPrompt`](/brute/reference/brute/system-prompt/)
instance to override — useful for SubAgents that need a specialized prompt
(e.g. the explore agent prompt):


```ruby
use Brute::Middleware::SystemPrompt,
    system_prompt: Brute::SystemPrompt.build { |p, _ctx|
      p.append Brute::Prompts.agent_prompt("explore")
    }
```

Skips injection when `env[:messages]` already contains a :system message (e.g.
from session.system(...)), so manually-set system prompts are respected.

## Class Methods

### self.new

```ruby
new(app, system_prompt: Brute::SystemPrompt.default)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/020_system_prompt.rb`
