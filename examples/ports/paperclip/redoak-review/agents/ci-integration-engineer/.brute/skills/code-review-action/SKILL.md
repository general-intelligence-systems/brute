---
name: code-review-action
description: >
  GitHub Actions workflow for automated pragmatic code review on pull requests, posting triage-leveled findings as PR comments
metadata:
  sources:
    - kind: github-file
      repo: OneRedOak/claude-code-workflows
      path: code-review/claude-code-review-custom.yml
      commit: 6a653445125da828f31af473fcdd3cf29f99be82
      attribution: Patrick Ellis
      license: MIT
      usage: referenced
---

GitHub Actions workflow configuration for running automated pragmatic code reviews on every pull request. Triggers on PR open, push, and re-review events. Posts findings as PR comments with triage levels and can block merge on Critical/Blocker findings. Use when setting up or maintaining CI-integrated code review pipelines.
