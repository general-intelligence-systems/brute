# Releasing Brute

The whole process, in order:

```sh
bin/test                      # 1. green suite
bin/increment-version minor   # 2. bump  (prints: now run bin/update-changelog)
bin/update-changelog          # 3. write the entry
bin/lint-changelog $VERSION   # 4. check it
git commit -am "Release ..."  # 5. commit the bump + changelog
bin/release-gem               # 6. build and push to RubyGems
bin/tag-version               # 7. tag
git push && git push --tags   # 8. publish the tag
```

Steps 2 and 6 are gates: they refuse to proceed when something is missing.
Everything below is what they check and why.

## Versioning

Brute is [semver](https://semver.org/). The version lives in one place —
`lib/brute/version.rb`, generated from `lib/brute/version.rb.erb` — and is only
ever changed by `bin/increment-version`.

| Segment | When | What it may contain |
| --- | --- | --- |
| **major** | A public name disappears or changes meaning | Removals of deprecated names, breaking signature changes |
| **minor** | New public surface, backwards compatible | New middleware, tools, transports, helpers; new deprecations |
| **patch** | Nothing new, nothing gone | Bug fixes, docs, internals |

Two rules that follow from this and are enforced in code:

- **Removals only ever land in a major version.** A name promised to disappear
  in `5.0` disappears in `5.0.0`, not in `4.9.1`.
- **Deprecating is a minor.** Adding a deprecation adds no obligation on the
  user *yet*, so it does not need a major — but it starts the clock. See
  [DEPRECATIONS.md](DEPRECATIONS.md).

The public surface is everything under `Brute::` that isn't marked internal:
the pipeline builders, middleware, tools, message transports, `Brute::Rack`,
and the shapes of `env` and `Brute::Message`.

## 1. Green suite

```sh
bin/test
```

Specs are co-located in each file's `__END__` block and run by
[scampi](https://github.com/general-intelligence-systems/scampi). A red suite
is not a release candidate; nothing downstream checks this for you.

## 2. Bump

```sh
bin/increment-version <major|minor|patch>
```

Rewrites `lib/brute/version.rb` from the ERB template, re-runs `bundle install`
so `Gemfile.lock` matches, and prints the transition:

```
4.1.0 -> 4.2.0

now run bin/update-changelog
```

**It refuses to bump onto a deprecation deadline.** If any registered
deprecation is due at the new version, it lists them with their source lines
and exits non-zero. Remove the deprecated code first — that is the point of the
promise. `--force` overrides and says so. Deprecations *not* yet due are
reported for information, not blocked on.

## 3. Changelog

```sh
bin/update-changelog
```

A thin wrapper around the `claude` CLI: it works out the current version and
the last tag, and asks Claude to read `git log <last-tag>..HEAD` (plus any
uncommitted work) and write the entry into `CHANGELOG.md`. It edits that one
file and does not commit.

Review what it writes. It is a first draft with the commits in front of it, not
an oracle — it cannot know which of two changes mattered to users.

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/):

```md
## [Unreleased]

## [4.2.0] - 2026-08-20

### Added

- Something users can now do.

### Deprecated

- `Old::Name` — use `New::Name` instead. Removed in 5.0.
```

Entries go under `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or
`Security` — those six and no others. `[Unreleased]` stays at the top, emptied
of anything that shipped in this version.

## 4. Lint the changelog

```sh
bin/lint-changelog            # format only
bin/lint-changelog 4.2.0      # format, plus "is 4.2.0 ready?"
```

Backed by [`Brute::Changelog`](lib/brute/changelog.rb). It checks the title,
that every heading is `## [Unreleased]` or `## [1.2.3] - YYYY-MM-DD`, that
versions are valid, dated, unique and ordered newest-first, that `###` sections
are one of the six types and none are empty — and, given a version, that the
version has a non-empty section sitting at the top of the released list.

Every problem is reported as `CHANGELOG.md:<line> <what>`.

## 5. Commit

The version bump, `Gemfile.lock` and the changelog belong in one commit, before
anything is pushed to RubyGems. A published gem whose changelog is still
unwritten in git is the failure this whole process exists to prevent.

## 6. Release the gem

```sh
bin/release-gem
```

Three gates, all before anything is built:

1. **Changelog** — `Brute::Changelog.release_problems(version)` must be empty:
   the version needs its own non-empty, correctly-formatted, topmost section.
2. **Deprecations** — nothing may be coming due in this version and still
   present in the tree.
3. **Remote version** — the local version must be strictly ahead of what is
   already on RubyGems.

Then `gem build` and `gem push`. Requires RubyGems push credentials.

## 7. Tag

```sh
bin/tag-version               # creates vX.Y.Z, refuses if it already exists
git push && git push --tags
```

The tag is also what `bin/update-changelog` uses next time to find the commit
range, so a missing tag makes the following release's changelog harder to
write.

## When something goes wrong

**Published a broken gem.** Don't delete it — `gem yank brute -v X.Y.Z` if it
is genuinely dangerous, otherwise ship a patch. Yanking a version other people
have already locked to breaks their builds.

**Bumped the version but the release failed.** The bump is just a file. Fix the
cause and re-run `bin/release-gem`; there is no need to un-bump.

**Changelog written for the wrong version.** Edit the heading and re-run
`bin/lint-changelog <version>`. Nothing downstream caches it.

## See also

- [DEPRECATIONS.md](DEPRECATIONS.md) — the deprecation policy the gates enforce.
- [CHANGELOG.md](CHANGELOG.md).
