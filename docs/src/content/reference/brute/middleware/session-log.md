---
title: "Brute::Middleware::SessionLog"
description: "The \"session\" is just a JSONL log of the conversation on disk."
---


```ruby
module Brute::Middleware
  class SessionLog < Base
  end
end
```

The "session" is just a JSONL log of the conversation on disk. This middleware
owns that log — there is no Session class.


```
in  -> if the file exists, prepend its messages to env[:messages] so
       this turn continues the prior conversation.
out <- write the log back to disk (skipping the :system message, which
       the SystemPrompt middleware re-adds each turn).
```

Put it near the top of the stack (outermost) so history is loaded before the
rest of the middleware runs and the whole turn is persisted after:


```ruby
Brute.agent
  .use(Brute::Middleware::SessionLog, path: "tmp/session.jsonl")
  .use(Brute::Middleware::SystemPrompt)
  ...
```

## Class Methods

### self.new

```ruby
new(app, path:)
```

*Not documented.*

## Instance Methods

### #call

```ruby
call(env)
```

*Not documented.*

## Defined in

- `lib/brute/middleware/002_session_log.rb`
