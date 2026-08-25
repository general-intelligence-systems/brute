---
title: "Brute::Tools::FSRead"
description: "Existing features (ref: opencode read tool):"
---


```ruby
module Brute::Tools
  class FSRead < Brute::Tool
  end
end
```

Existing features (ref: opencode read tool):

1.  Default line limit — cap reads at 2000 lines when no start_line/end_line
    given, instead of reading the entire file.
2.  Byte cap — stop reading when cumulative output exceeds 50 KB
    ([`MAX_BYTES`](/brute/reference/brute/tools/fs-read/#max_bytes)).
    Whichever limit (lines or bytes) is hit first wins.
3.  Per-line truncation — truncate individual lines longer than 2000 chars
    with a suffix like "... (line truncated to 2000 chars)".
4.  Pagination hint — when output is truncated, append a hint: "(Showing lines
    1-N of M. Use start_line=N+1 to continue.)" When reading completes, append
    "(End of file - total N lines)".
5.  Binary file detection — read first 4 KB sample, check for null bytes and
    known binary extensions (.zip, .exe, .so, .pyc, etc.). Reject with "Cannot
    read binary file: (path)".
6.  Directory listing — when file_path points to a directory, list entries
    (paginated, respecting limit) instead of raising an error.
7.  File-not-found suggestions — on miss, scan the parent directory for
    similar names and suggest "Did you mean...?" candidates.
8.  Return a plain string instead of a Hash — avoids the .to_s repr bloat when
    ToolPipeline coerces the result for the LLM message.

## Constants

### BINARY_EXTENSIONS

```ruby
BINARY_EXTENSIONS = %w[.zip .exe .so .pyc .pyo .dll .dylib .bin .o .a .tar .gz .bz2 .xz .7z .rar .jar .war .class .png .jpg .jpeg .gif .bmp .ico .pdf .woff .woff2 .ttf .eot .mp3 .mp4 .avi .mov .flv .wmv .db .sqlite .sqlite3].freeze
```

*Not documented.*

### DEFAULT_LINE_CAP

```ruby
DEFAULT_LINE_CAP = 2000
```

*Not documented.*

### MAX_BYTES

```ruby
MAX_BYTES = Brute::Truncation::MAX_BYTES
```

*Not documented.*

### MAX_LINE_LENGTH

```ruby
MAX_LINE_LENGTH = Brute::Truncation::MAX_LINE_LENGTH
```

*Not documented.*

## Instance Methods

### #execute

```ruby
execute(file_path:, start_line: nil, end_line: nil)
```

*Not documented.*

### #name

```ruby
name()
```

*Not documented.*

## Defined in

- `lib/brute/tools/fs_read.rb`
