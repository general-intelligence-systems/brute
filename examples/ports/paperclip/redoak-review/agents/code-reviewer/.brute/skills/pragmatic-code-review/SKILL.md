---
name: pragmatic-code-review
description: >
  Perform a 7-tier hierarchical code quality review covering Architecture, Functionality, Security, Maintainability, Testing, Performance, and Dependencies with triage levels (Critical/Blocker, Improvement, Nit)
metadata:
  sources:
    - kind: github-file
      repo: OneRedOak/claude-code-workflows
      path: code-review/pragmatic-code-review-subagent.md
      commit: 6a653445125da828f31af473fcdd3cf29f99be82
      attribution: Patrick Ellis
      license: MIT
      usage: referenced
---

Perform a structured code quality review using the Pragmatic Quality framework. Reviews code through a 7-tier hierarchy — Architecture, Functionality, Security, Maintainability, Testing, Performance, Dependencies — and triages every finding as Critical/Blocker, Improvement, or Nit. Use when reviewing pull requests, feature branches, or entire codebases for code quality.
