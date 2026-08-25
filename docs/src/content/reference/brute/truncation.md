---
title: "Brute::Truncation"
description: "Universal tool output truncation."
---


```ruby
module Brute
  module Truncation
  end
end
```

Universal tool output truncation.

Every tool result passes through
[`Truncation.truncate()`](/brute/reference/brute/truncation/#selftruncate)
before entering the LLM context. This is the primary guard against context
window explosion — even if a tool has no internal limits, this module caps the
output to a safe size.

Existing features (ref: opencode truncate.ts):

1.  Line + byte dual cap — truncate when output exceeds
    [`MAX_LINES`](/brute/reference/brute/truncation/#max_lines) (2000) or
    [`MAX_BYTES`](/brute/reference/brute/truncation/#max_bytes) (50 KB),
    whichever is hit first.
2.  Head mode (default) — keep the first N lines / bytes. Used for most tool
    output where the beginning is most relevant.
3.  Tail mode — keep the last N lines / bytes. Used for shell output where
    errors and summaries appear at the end.
4.  Overflow to disk — when truncating, write the full text to a file under
    [`TRUNCATION_DIR`](/brute/reference/brute/truncation/#truncation_dir)
    (e.g. ~/.local/share/brute/tool-output/). Return a preview + hint pointing
    to the saved file.
5.  Hint message — when truncated, append a contextual hint: "Full output
    saved to: (path). Use Read with offset/limit to view specific sections."
6.  Configurable limits — allow overriding
    [`MAX_LINES`](/brute/reference/brute/truncation/#max_lines) /
    [`MAX_BYTES`](/brute/reference/brute/truncation/#max_bytes) via per-call
    options.
7.  Retention cleanup — purge saved output files older than a configurable
    retention period from a truncation directory.
8.  Per-line truncation — truncate individual lines longer than
    [`MAX_LINE_LENGTH`](/brute/reference/brute/truncation/#max_line_length)
    (2000 chars) with a suffix.

## Constants

### MAX_BYTES

```ruby
MAX_BYTES = 50 * 1024
```

*Not documented.*

### MAX_LINES

```ruby
MAX_LINES = 2000
```

*Not documented.*

### MAX_LINE_LENGTH

```ruby
MAX_LINE_LENGTH = 2000
```

*Not documented.*

### TRUNCATION_DIR

```ruby
TRUNCATION_DIR = File.join(Dir.home, ".local", "share", "brute", "tool-output")
```

*Not documented.*

### TRUNCATION_MARKER

```ruby
TRUNCATION_MARKER = "[Output truncated:"
```

*Not documented.*

## Class Methods

### self.already_truncated?

```ruby
already_truncated?(text)
```

Check whether text already contains a truncation marker.

### self.cleanup!

```ruby
cleanup!(dir, retention_days: 7)
```

Purge files older than retention_days from the given directory.

### self.truncate

```ruby
truncate(text, max_lines: MAX_LINES, max_bytes: MAX_BYTES, direction: :head, truncation_dir: nil)
```

Truncate text to fit within line and byte limits.

Returns the text unchanged if it fits. Otherwise returns a truncated preview
with a hint message.

@parameter text [String] the tool output to truncate @parameter max_lines
[Integer] maximum number of lines to keep @parameter max_bytes [Integer]
maximum byte size to keep @parameter direction [Symbol] which end to keep
@parameter truncation_dir [String, nil] directory to save full output when
truncating @returns [String] the (possibly truncated) text

### self.truncate_line

```ruby
truncate_line(line, max: MAX_LINE_LENGTH)
```

Truncate a single line if it exceeds
[`MAX_LINE_LENGTH`](/brute/reference/brute/truncation/#max_line_length).

## Defined in

- `lib/brute/truncation.rb`
