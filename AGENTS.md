## References

- Harness engineering https://github.com/walkinglabs/learn-harness-engineering

## Testing

- Test framework is `scampi` usage here: https://raw.githubusercontent.com/general-intelligence-systems/scampi/refs/heads/trench/README.md
- Run tests with `bin/test`

## Deprecations

- Read [DEPRECATIONS.md](DEPRECATIONS.md) before removing or renaming any public name.
- Never delete a public name outright — deprecate it with `GemKit::Deprecate`
  (`extend` it, then `deprecate` a method or `superseded_by` a moved constant),
  naming the replacement and the version it will be removed in.
- Removals land in major versions only. `gem kit deprecations` lists what is outstanding.

## Releasing

- The process, and the versioning rules, are in [RELEASE.md](RELEASE.md).
- The toolchain is the [gem_kit-release](https://rubygems.org/gems/gem_kit-release)
  gem, a development dependency: `gem kit bump|changelog|deprecations|release|tag`.
  Run `gem kit` for the list, `gem kit help <command>` for one.
- Never edit `lib/brute/version.rb` by hand; use `gem kit bump <major|minor|patch>`.
- Every release needs a `CHANGELOG.md` entry — `gem kit changelog --write` writes it,
  `gem kit changelog` checks it, and `gem kit release` refuses without it.
