---
title: "Brute::Messages"
description: "The in-memory conversation log is just a plain Array of Brute::Message."
---


```ruby
module Brute
  module Messages
  end
end
```

The in-memory conversation log is just a plain Array of
[`Brute::Message`](/brute/reference/brute/#message). This module adds a little
sugar for appending role-tagged messages; mix it into an array via
<code>Brute.log</code>. Persistence is NOT here — loading/saving the log to
disk is the
[`Brute::Middleware::SessionLog`](/brute/reference/brute/middleware/session-lo
g/) middleware's job.

## Instance Methods

### #assistant

```ruby
assistant(content)
```

*Not documented.*

### #system

```ruby
system(content)
```

*Not documented.*

### #tool

```ruby
tool(content, tool_call_id:)
```

*Not documented.*

### #user

```ruby
user(content)
```

*Not documented.*

## Defined in

- `lib/brute/messages.rb`
