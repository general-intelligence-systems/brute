---
title: "Brute::Contrib::LogFile"
description: "A line-oriented, append-only log file that doubles as a work queue."
---


```ruby
module Brute::Contrib
  class LogFile < File
    include File::Tail
  end
end
```

A line-oriented, append-only log file that doubles as a work queue.

Every entry is exactly one line — newlines in the input are folded to spaces
on the way in — so a line is the unit of both storage and retrieval. Reads are
destructive: `pop` takes the newest line off the end, `drain` yields every
line oldest-first and empties the file.


```ruby
log = Brute::Contrib::LogFile.new("tmp/queue.log")
log.append("something happened")
log.pop            # => "something happened"
log.drain { |line| handle(line) }
```

Safe across both threads (a mutex) and processes (an exclusive flock), so
several agents can share one file without losing lines.

## Class Methods

### self.new

```ruby
new(path)
```

*Not documented.*

## Instance Methods

### #append

```ruby
append(line)
```

Append one line. Blank (or whitespace-only) input is a no-op and returns nil;
otherwise returns the stripped line that was written.

### #drain

```ruby
drain() { |chomp| ... }
```

Yield every line oldest-first, then empty the file. Requires a block —without
one there is nowhere for the lines to go, so it raises rather than discarding
them.

### #pop

```ruby
pop()
```

Remove and return the newest line, or nil when the file is empty.

## Defined in

- `lib/brute/contrib/log_file.rb`
