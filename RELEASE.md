# Releasing brute

The whole process, in order:

```sh
bin/test                      # 1. green suite
gem kit bump minor            # 2. bump  (prints: now run gem kit changelog --write)
gem kit changelog --write     # 3. write the entry
gem kit changelog <VERSION>   # 4. check it
git commit -am "Release ..."  # 5. commit the bump + changelog
gem kit release               # 6. build and push
gem kit tag --push            # 7. tag it
```

Steps 2 and 6 are gates: they refuse to proceed when something is missing.
Everything below is what they check and why.

## Versioning

brute is [semver](https://semver.org/). The version lives in one place —
`lib/brute/version.rb` — and is only ever changed by `gem kit bump`.

| Segment | When | What it may contain |
| --- | --- | --- |
| **major** | A public name disappears or changes meaning | Removals of deprecated names, breaking signature changes |
| **minor** | New public surface, backwards compatible | New classes and methods; new deprecations |
| **patch** | Nothing new, nothing gone | Bug fixes, docs, internals |

Two rules follow from this, and both are enforced in code:

- **Removals only ever land in a major version.** A name promised to disappear
  in 5 disappears in 5.0.0, not in a patch.
- **Deprecating is a minor.** Adding a deprecation puts no obligation on the
  user *yet*, so it does not need a major — but it starts the clock. See
  [DEPRECATIONS.md](DEPRECATIONS.md).

## 1. Green suite

```sh
bin/test
```

A red suite is not a release candidate; nothing downstream checks this for you.

## 2. Bump

```sh
gem kit bump <major|minor|patch>
```

Rewrites `lib/brute/version.rb` — by rendering its `.erb` template if there is
one, otherwise by substituting the version literal in place — and prints the
transition:

```
4.1.0 -> ...

now run: gem kit changelog --write
```

**It refuses to bump onto a deprecation deadline.** If any registered
deprecation is due at the new version, it lists them with their source lines
and fails. Remove the deprecated code first — that is the point of the promise.
`--force` overrides and says what it overrode. Deprecations *not* yet due are
reported for information, not blocked on.

## 3. Changelog

```sh
gem kit changelog --write
```

Hands the entry to the AI CLI named by `config.changelog_writer` (default:
`claude`), with a prompt describing the format and this project's conventions.
It reads the commits since the last tag and edits `CHANGELOG.md` only.

Review what it writes. It is a first draft with the commits in front of it, not
an oracle — it cannot know which of two changes mattered to users.

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/):

```md
## [Unreleased]

## [4.1.0] - 2026-08-20

### Added

- Something users can now do.

### Deprecated

- `Old::Name` — use `New::Name` instead. Removed in 5.
```

Entries go under `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or
`Security` — those six and no others. `[Unreleased]` stays at the top, emptied
of anything that shipped.

## 4. Lint the changelog

```sh
gem kit changelog              # format only
gem kit changelog 4.1.0       # format, plus "is this version ready?"
```

Checks the title, that every heading is `## [Unreleased]` or
`## [1.2.3] - YYYY-MM-DD`, that versions are valid, dated, unique and ordered
newest-first, that `###` sections are one of the six types and none are empty —
and, given a version, that it has a non-empty section at the top of the released
list. Every problem is reported as `CHANGELOG.md:<line> <what>`.

## 5. Commit

The version bump, the lockfile and the changelog belong in one commit, before
anything is pushed to RubyGems. A published gem whose changelog is still
unwritten in git is the failure this process exists to prevent.

## 6. Release

```sh
gem kit release           # or: gem kit release --dry-run, which is the CI check
```

Two gates, both before `gem build` runs:

1. **Changelog** — this version needs its own non-empty, correctly formatted
   section, sitting at the top of the released list.
2. **Deprecations** — nothing promised to disappear in this version may still
   be in the tree.

Then `gem build` and `gem push`. Requires RubyGems push credentials.

## 7. Tag

```sh
gem kit tag --push
```

Creates `v4.1.0`, refusing if it already exists. The tag is also what
the next `gem kit changelog --write` uses to find the commit range, so a missing
one makes the following release's changelog harder to write.

## When something goes wrong

**Published a broken gem.** Don't delete it — `gem yank brute -v X.Y.Z` if
it is genuinely dangerous, otherwise ship a patch. Yanking a version other
people have already locked to breaks their builds.

**Bumped but the release failed.** The bump is just a file. Fix the cause and
re-run `gem kit release`; there is no need to un-bump.

**Changelog written for the wrong version.** Edit the heading and re-run
`gem kit changelog <version>`. Nothing downstream caches it.

## See also

- [DEPRECATIONS.md](DEPRECATIONS.md) — the deprecation policy the gates enforce.
- [CHANGELOG.md](CHANGELOG.md).
