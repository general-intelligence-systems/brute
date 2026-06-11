---
name: design-review-action
description: >
  GitHub Actions integration for automated design review on pull requests that modify frontend files
metadata:
  sources:
    - kind: github-file
      repo: OneRedOak/claude-code-workflows
      path: design-review/design-review-slash-command.md
      commit: 6a653445125da828f31af473fcdd3cf29f99be82
      attribution: Patrick Ellis
      license: MIT
      usage: referenced
---

GitHub Actions integration for running automated design review checks on pull requests that modify frontend files. Covers automatable checks like accessibility attributes, semantic HTML, and responsive meta tags. Flags PRs that need full visual review by the Design Reviewer. Use when setting up or maintaining CI-integrated design review pipelines.
