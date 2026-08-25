---
title: "Brute::Tools"
description: "Module Brute::Tools."
---


```ruby
module Brute
  module Tools
  end
end
```

## Constants

### ALL

```ruby
ALL = [
      Tools::FSRead,
      Tools::FSWrite,
      Tools::FSPatch,
      Tools::FSRemove,
      Tools::FSSearch,
      Tools::FSUndo,
      Tools::Shell,
      Tools::NetFetch,
      Tools::TodoWrite,
      Tools::TodoRead,
      Tools::Question,
      Tools::SkillLoad
    ].freeze
```

*Not documented.*

## Defined in

- `lib/brute/tools.rb`
- `lib/brute/tools/adapter.rb`
- `lib/brute/tools/fs/file_mutation_queue.rb`
- `lib/brute/tools/fs/snapshot_store.rb`
- `lib/brute/tools/fs_patch.rb`
- `lib/brute/tools/fs_read.rb`
- `lib/brute/tools/fs_remove.rb`
- `lib/brute/tools/fs_search.rb`
- `lib/brute/tools/fs_undo.rb`
- `lib/brute/tools/fs_write.rb`
- `lib/brute/tools/net_fetch.rb`
- `lib/brute/tools/question.rb`
- `lib/brute/tools/shell.rb`
- `lib/brute/tools/skill_load.rb`
- `lib/brute/tools/sub_agent.rb`
- `lib/brute/tools/todo_list/store.rb`
- `lib/brute/tools/todo_read.rb`
- `lib/brute/tools/todo_write.rb`
