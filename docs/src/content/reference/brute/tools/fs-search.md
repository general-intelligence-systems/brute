---
title: "Brute::Tools::FSSearch"
description: "Existing features (ref: opencode grep tool):"
---


```ruby
module Brute::Tools
  class FSSearch < Brute::Tool
  end
end
```

Existing features (ref: opencode grep tool):

1.  Global result cap — limit total matches to 100 across all files.
2.  Per-line truncation — truncate individual match lines longer than 2000
    chars via rg --max-columns with preview.
3.  Structured truncation message — when results are capped, append: "(Results
    truncated: showing 100 of N matches. Consider a more specific path or
    pattern.)"
4.  Sort results by file mtime — most-recently-modified files first, so the
    LLM sees the most relevant matches first.
5.  Return a plain string instead of a Hash.
6.  Align output cap with universal truncation (2000 lines / 50 KB).

## Constants

### MAX_TOTAL_MATCHES

```ruby
MAX_TOTAL_MATCHES = 100
```

*Not documented.*

## Instance Methods

### #execute

```ruby
execute(pattern:, path: nil, glob: nil, ignore_case: false)
```

*Not documented.*

### #name

```ruby
name()
```

*Not documented.*

## Defined in

- `lib/brute/tools/fs_search.rb`
