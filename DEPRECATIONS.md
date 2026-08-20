# Deprecations

A deprecation in brute is a **dated promise**: it names the replacement
*and* the version the old name stops existing in. That promise is
machine-readable — every declaration registers itself, and the release tooling
refuses to ship a version that breaks one.

The mechanism is [`GemKit::Deprecate`](https://rubygems.org/gems/gem_kit),
built on [`Gem::Deprecate`](https://docs.ruby-lang.org/en/master/Gem/Deprecate.html).

## The rules

1. **Never delete a public name outright.** Leave it working, deprecated, until
   its deadline.
2. **Every deprecation names a removal version.** The current version is 4.1.0, so the usual deadline is 5.0.
3. **Removals happen in major versions only.** A minor or patch release never
   takes a name away.
4. **The deadline is enforced, not remembered.** `gem kit bump` and `gem kit release`
   both refuse to move to a version that has a deprecation coming due.
5. **Deprecating something is a changelog entry** — under `### Deprecated`,
   naming the replacement and the removal version.

## Deprecating a method

```ruby
class Session
  extend GemKit::Deprecate

  def new_reset
    # ...
  end

  def old_reset = new_reset

  deprecate :old_reset, "Session#new_reset", "5.0"
end
```

The old method keeps working and warns on every call, naming the caller:

```
NOTE: Session#old_reset is deprecated; use Session#new_reset instead.
It will be removed in 5.0
Session#old_reset called from app.rb:12.
```

Use `:none` as the replacement when there genuinely isn't one:

```ruby
deprecate :old_reset, :none, "5.0"
```

For a class method, follow the `Gem::Deprecate` idiom — the registry records it
against the class, not its singleton:

```ruby
class << self
  extend GemKit::Deprecate
  deprecate :some_class_method, "Other.method", "5.0"
end
```

## Deprecating a renamed or moved constant

Keep the old constant as a subclass of the new one and declare the rename in
its body:

```ruby
module Old
  class Thing < New::Thing
    extend GemKit::Deprecate
    superseded_by "New::Thing", "5.0"
  end
end
```

Old code keeps running unchanged; instantiating the old name warns and points at
the new one. The whole shim is those four lines — the implementation lives in
one place.

It is `superseded_by` rather than `deprecate_constant` because `Module` already
has a method by that name, and shadowing it would break callers who use it.

## Finding what is outstanding

```sh
gem kit deprecations
```

```
1 outstanding deprecation(s) (current version 4.1.0):
  5.0      Session#old_reset -> Session#new_reset
           lib/session.rb:19
```

Pass a version to ask "what comes due here?" — it exits non-zero if anything
does, which is what makes it usable as a gate in CI:

```sh
gem kit deprecations 5.0.0
```

Programmatically, the same data:

```ruby
GemKit::Deprecate.registry                  # every declaration
GemKit::Deprecate.pending("5.0.0")   # deadlines that have arrived
GemKit::Deprecate.upcoming("5.0.0")  # still in their grace period
```

Each entry carries `name`, `replacement`, `removed_in` and `declared_at`.

## Paying the debt

When a major version comes around, the bump is blocked until the deprecated
code is actually gone:

```
$ gem kit bump major
ERROR:  Refusing to bump 4.1.0 -> 5.0.0:

  5.0      Session#old_reset -> Session#new_reset
           lib/session.rb:19

  Remove them, then bump. Override with --force.
```

So the order of work is:

1. `gem kit deprecations 5.0.0` — read the list.
2. Delete each deprecated name and its specs. For a constant shim, that means
   deleting the whole file.
3. Update anything in `examples/` and the docs still using the old name.
4. Record the removals in `CHANGELOG.md` under `### Removed`.
5. `gem kit bump major` — now it goes through.

`--force` exists for the case where you have decided to extend a grace period,
and it prints what it is overriding. It is not the normal path: extending a
deadline properly means editing the declaration's version, which keeps the
registry honest.

## Testing deprecated code

`Gem::Deprecate.skip_during` silences these warnings too, so a spec can
exercise the old path without noise:

```ruby
Gem::Deprecate.skip_during do
  legacy.old_reset
end
```

To assert *that* something warns, stub the single funnel every warning goes
through:

```ruby
captured = []
original = GemKit::Deprecate.method(:warn)
GemKit::Deprecate.define_singleton_method(:warn) { |message| captured << message }
begin
  legacy.old_reset
ensure
  GemKit::Deprecate.define_singleton_method(:warn, original)
end
```

## See also

- [RELEASE.md](RELEASE.md) — where the deprecation gates sit in the release
  process.
- The changelog — its `### Deprecated` and `### Removed` sections are the
  user-facing half of all this.
