---
title: "Brute::Tools::FS::SnapshotStore"
description: "Per-path stack of file snapshots used by fs_write, fs_patch, fs_remove to enable undo."
---


```ruby
module Brute::Tools::FS
  module SnapshotStore
  end
end
```

Per-path stack of file snapshots used by fs_write, fs_patch, fs_remove to
enable undo. Each call to .save pushes the current content (or :did_not_exist
for new files). .pop retrieves the most recent snapshot.

## Class Methods

### self.clear!

```ruby
clear!()
```

Clear all snapshots. Used in tests and session resets.

### self.pop

```ruby
pop(path)
```

Pop and return the most recent snapshot for `path`, or `nil` if there is no
history.

### self.save

```ruby
save(path)
```

Push the current content of `path` onto the snapshot stack. If the file
doesn't exist yet, records <code>:did_not_exist</code>.

## Defined in

- `lib/brute/tools/fs/snapshot_store.rb`
