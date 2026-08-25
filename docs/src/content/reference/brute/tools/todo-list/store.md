---
title: "Brute::Tools::TodoList::Store"
description: "In-memory todo list storage."
---


```ruby
module Brute::Tools::TodoList
  module Store
  end
end
```

In-memory todo list storage. The agent uses this to track multi-step tasks via
the todo_read / todo_write tools. The list is replaced wholesale on each
todo_write call.

## Class Methods

### self.all

```ruby
all()
```

Return all current items.

### self.clear!

```ruby
clear!()
```

Clear all items.

### self.replace

```ruby
replace(items)
```

Replace the entire todo list.

## Defined in

- `lib/brute/tools/todo_list/store.rb`
