# Kernel-backed (Ruby) skills

The package contract for skills the agent *calls* from IRuby cells — this
port's equivalent of prime-agent's Python-backed skills
(`skills/skill-creator/references/python-skills.md` upstream).

## What makes a skill kernel-backed

A skill directory with a `lib/` dir containing Ruby files:

```
my-skill/
├── SKILL.md
└── lib/
    └── my_skill.rb       # import name = file basename
```

The kernel bootstrap puts every skill's `lib/` directory on the IRuby load
path (`skill_lib_glob`), so cells can:

```ruby
require "my_skill"
MySkill.run(...)
```

Conventions:

- **Import name**: the file basename. Keep it aligned with the skill name —
  hyphens become underscores (`my-skill` → `my_skill.rb`). The prompt's
  `<ruby_import>` field carries it.
- **Module + module_function**: define a module named after the import
  (`MySkill`) with `module_function` methods. `run(...)` is the canonical
  entry point (see the bundled `edit` skill).
- **Pure stdlib.** The kernel is a bare IRuby process: no gems, no brute.
  `json`, `net/http`, `fileutils`, `digest` etc. are fine.
- **Errors raise.** A raised exception renders as the cell's error result,
  which is how the model sees validation failures (`edit` raises on 0 or >1
  matches). Setup problems should *return instructions*, not raise, when the
  model can walk the user through fixing them (see `websearch`).
- **Long outputs**: keep results modest; tool results are tail-truncated at
  2000 lines / 50 KB by the host.

## Concurrent edits

If the skill mutates files and KernelAgents may call it concurrently,
serialize per file with a mutex keyed on the realpath — copy the
`Edit::MutationQueue` pattern from the bundled edit skill (same-file
operations serialize, different files run in parallel, the map self-cleans).

## Host-visible side channels

A skill can stream a diff to the host over `display_data` — the edit skill
emits `{path, old_str, new_str, start_line}` under the
`application/vnd.prime-agent.diff+json` MIME via
`IRuby::Kernel.instance.session.send(:publish, :display_data, ...)`, always
best-effort (a display failure must never break the cell). The host renders
it into the tool result as a `+/-` block and compaction tracks the file as
modified.

## Checklist

1. `require "<import name>"` works from a cell.
2. Each documented function returns (or raises) as the SKILL.md says.
3. No gem requires; nothing outside stdlib.
4. Results stay small or truncate deliberately.
5. File mutations go through a per-file mutex when agents can race.
