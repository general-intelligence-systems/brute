---
title: "Brute::Tools::Shell"
description: "Existing features (ref: opencode bash tool):"
---


```ruby
module Brute::Tools
  class Shell < Brute::Tool
  end
end
```

Existing features (ref: opencode bash tool):

1.  Tail-mode truncation — when output exceeds limits, keep the LAST N lines /
    bytes instead of the first. Command output typically has the important
    info (errors, summaries) at the end.
2.  Save full output to disk — when truncating, write the complete output to a
    temp file and include the path in the truncated result so the LLM can use
    Read with offset/limit to inspect it.
3.  Align limits with universal truncation (2000 lines / 50 KB).
4.  Configurable per-call timeout — accept a timeout parameter from the LLM
    (defaults to 5 minutes).
5.  Return a plain string instead of a Hash.

## Constants

### DEFAULT_TIMEOUT

```ruby
DEFAULT_TIMEOUT = 300
```

*Not documented.*

## Instance Methods

### #execute

```ruby
execute(command:, cwd: nil, timeout: nil)
```

*Not documented.*

### #name

```ruby
name()
```

*Not documented.*

## Defined in

- `lib/brute/tools/shell.rb`
