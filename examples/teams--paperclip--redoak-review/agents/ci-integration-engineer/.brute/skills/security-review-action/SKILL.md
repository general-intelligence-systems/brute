---
name: security-review-action
description: >
  GitHub Actions workflow for automated security review on pull requests with confidence-gated PR comments
metadata:
  sources:
    - kind: github-file
      repo: OneRedOak/claude-code-workflows
      path: security-review/security.yml
      commit: 6a653445125da828f31af473fcdd3cf29f99be82
      attribution: Patrick Ellis
      license: MIT
      usage: referenced
---

GitHub Actions workflow configuration for running automated security reviews on every pull request. Applies the same 3-phase security methodology with false-positive filtering and confidence scoring. Only posts findings with confidence >= 0.8 as PR comments. Can block merge on HIGH severity findings. Use when setting up or maintaining CI-integrated security review pipelines.
