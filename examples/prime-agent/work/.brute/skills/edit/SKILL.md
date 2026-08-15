---
name: edit
description: Replace an exact, unique string in an existing file. Use for targeted single-occurrence edits to files from the IRuby kernel instead of rewriting the whole file.
---

# Edit

Make a targeted edit to an existing file by replacing one exact, unique
occurrence of a string. `old_str` must appear exactly once in the file.

Call directly from IRuby:

    require "edit"
    Edit.run(path: "pkg/file.rb", old_str: old, new_str: new)

Use exact old/new strings. Returns a short confirmation; raises if `old_str`
is missing or matches more than once (widen the snippet to make it unique).
Every edit also streams a diff display to the host over `display_data`
(`{path, old_str, new_str, start_line}`), rendered into the tool result as a
`+/-` block — the same side channel prime-agent's TUI uses.
