# Deprecations

A deprecation in Brute is a **dated promise**: it names the replacement *and*
the version the old name stops existing in. That promise is machine-readable —
every declaration registers itself, and the release tooling refuses to ship a
version that breaks one.

The mechanism is [`Brute::Deprecate`](lib/brute/deprecate.rb), built on
[`Gem::Deprecate`](https://docs.ruby-lang.org/en/master/Gem/Deprecate.html).

## The rules

1. **Never delete a public name outright.** Leave it working, deprecated, until
   its deadline.
2. **Every deprecation names a removal version.** The default is the next major
   (`Brute::Deprecate.next_major_version`); pass an explicit one if the grace
   period should be longer.
3. **Removals happen in major versions only.** A minor or patch release never
   takes a name away.
4. **The deadline is enforced, not remembered.** `bin/increment-version` and
   `bin/release-gem` both refuse to move to a version that has a deprecation
   coming due.
5. **Deprecating something is a changelog entry** — under `### Deprecated`,
   naming the replacement and the removal version.

## Deprecating a method

```ruby
class Session
  extend Brute::Deprecate

  def new_reset
    # ...
  end

  def old_reset = new_reset

  brute_deprecate :old_reset, "Session#new_reset", "5.0"
end
```

The old method keeps working and warns on every call, in `Gem::Deprecate`'s
format, naming the caller:

```
NOTE: Session#old_reset is deprecated; use Session#new_reset instead.
It will be removed in Brute 5.0
Session#old_reset called from app.rb:12.
```

Use `:none` as the replacement when there genuinely isn't one:

```ruby
brute_deprecate :old_reset, :none, "5.0"
```

For a class method, follow the `Gem::Deprecate` idiom:

```ruby
class << self
  extend Brute::Deprecate
  brute_deprecate :some_class_method, "Other.method", "5.0"
end
```

## Deprecating a renamed or moved constant

Keep the old constant as a subclass of the new one and declare the rename in
its body. This is what happened when the completion middlewares moved out of
`Brute::Middleware`:

```ruby
# lib/brute/middleware/open_router.rb
module Brute
  module Middleware
    module OpenRouter
      class Completion < Brute::Completion::OpenRouter
        extend Brute::Deprecate
        brute_deprecate_constant "Brute::Completion::OpenRouter", "5.0"
      end
    end
  end
end
```

Old code keeps running unchanged; instantiating the old name warns and points
at the new one. The whole shim is those four lines — the implementation lives
in one place.

`brute_deprecate_constant` takes the replacement's name and the removal
version, and registers under the constant's own name. It wraps `.new` when the
constant is a class; for a plain module it registers the deadline without
wrapping anything.

## Finding what is outstanding

```sh
bin/deprecations
```

```
1 outstanding deprecation(s) (current version 4.1.0):
  5.0      Brute::Middleware::OpenRouter::Completion -> Brute::Completion::OpenRouter
           lib/brute/middleware/open_router.rb:19
```

Pass a version to ask "what comes due here?" — it exits non-zero if anything
does, which is what makes it usable as a gate in CI:

```sh
bin/deprecations 5.0.0
```

Programmatically, the same data:

```ruby
Brute::Deprecate.registry            # every declaration, in load order
Brute::Deprecate.pending("5.0.0")    # deadlines that have arrived
Brute::Deprecate.upcoming("5.0.0")   # still in their grace period
```

Each entry carries `name`, `replacement`, `removed_in` and `declared_at` (the
source location of the declaration).

## Paying the debt

When a major version comes around, the bump is blocked until the deprecated
code is actually gone:

```
$ bin/increment-version major
Refusing to bump 4.1.0 -> 5.0.0: 1 deprecation(s) come due in 5.0.0.

  5.0      Brute::Middleware::OpenRouter::Completion -> Brute::Completion::OpenRouter
           lib/brute/middleware/open_router.rb:19

Remove them, then bump. See bin/deprecations. Override with --force.
```

So the order of work is:

1. `bin/deprecations 5.0.0` — read the list.
2. Delete each deprecated name and its specs. For a constant shim, that means
   deleting the whole file.
3. Update anything in `examples/` and `docs/` still using the old name.
4. Record the removals in the changelog under `### Removed`.
5. `bin/increment-version major` — now it goes through.

`--force` exists for the case where you have decided to extend a grace period,
and it prints what it is overriding. It is not the normal path: extending a
deadline properly means editing the declaration's version, which keeps the
registry honest.

## Testing deprecated code

`Gem::Deprecate.skip_during` silences Brute's warnings too, so a spec can
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
original = Brute::Deprecate.method(:warn)
Brute::Deprecate.define_singleton_method(:warn) { |message| captured << message }
begin
  Brute::Middleware::OpenRouter::Completion.new(app)
ensure
  Brute::Deprecate.define_singleton_method(:warn, original)
end
```

## See also

- [RELEASE.md](RELEASE.md) — where the deprecation gates sit in the release
  process.
- [CHANGELOG.md](CHANGELOG.md) — the `### Deprecated` and `### Removed`
  sections are the user-facing half of all this.
