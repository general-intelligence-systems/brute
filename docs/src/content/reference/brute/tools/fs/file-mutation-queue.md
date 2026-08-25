---
title: "Brute::Tools::FS::FileMutationQueue"
description: "Per-file serialization queue for concurrent tool execution."
---


```ruby
module Brute::Tools::FS
  module FileMutationQueue
  end
end
```

Per-file serialization queue for concurrent tool execution.

When tools run in parallel (via threads or async fibers), multiple tools may
target the same file simultaneously. Without serialization, a sequence like
[read → patch → write] on the same file would race and lose edits.

This module provides a single public method:


```ruby
Brute::Tools::FS::FileMutationQueue.serialize("/path/to/file") do
  # snapshot + read + modify + write — all atomic for this path
end
```

Design (mirrors pi-mono's withFileMutationQueue):

```
- Operations on the SAME file are serialized (run one at a time)
- Operations on DIFFERENT files run fully in parallel (independent mutexes)
- Symlink-aware: resolves real paths so aliases share one mutex
- Error-safe: mutex is always released in `ensure`, so failures never deadlock
- Self-cleaning: per-file mutexes are removed when no longer in use
```

Ruby 3.4's Mutex is fiber-scheduler-aware, so this works correctly with both
:thread and :task (Async) concurrency strategies.

## Class Methods

### self.clear!

```ruby
clear!()
```

Clear all tracked mutexes. Used in tests and session resets.

### self.serialize

```ruby
serialize(path, &block)
```

Serialize a block of work for a given file path.

Concurrent calls targeting the same canonical path will execute sequentially
in FIFO order. Calls targeting different paths proceed in parallel with zero
contention.

@parameter path [String] The file path to serialize on. @yields {block} The
mutation work to perform (snapshot, read, write, etc.) @returns Whatever the
block returns.

### self.size

```ruby
size()
```

Number of file paths currently tracked (for diagnostics).

## Defined in

- `lib/brute/tools/fs/file_mutation_queue.rb`
