## References

- Harness engineering https://github.com/walkinglabs/learn-harness-engineering

## Testing

- Test framework is `scampi` usage here: https://raw.githubusercontent.com/general-intelligence-systems/scampi/refs/heads/trench/README.md
- Run tests with `bin/test`

## Deprecations

- Read [DEPRECATIONS.md](DEPRECATIONS.md) before removing or renaming any public name.
- Never delete a public name outright — deprecate it with `Brute::Deprecate`,
  naming the replacement and the version it will be removed in.
- Removals land in major versions only. `bin/deprecations` lists what is outstanding.

## Releasing

- The process, and the versioning rules, are in [RELEASE.md](RELEASE.md).
- Never edit `lib/brute/version.rb` by hand; use `bin/increment-version <major|minor|patch>`.
- Every release needs a `CHANGELOG.md` entry — `bin/update-changelog` writes it,
  `bin/lint-changelog` checks it, and `bin/release-gem` refuses without it.
