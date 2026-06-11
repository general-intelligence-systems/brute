---
name: using-git-worktrees
description: "Use when starting feature work that needs isolation from current workspace or before executing implementation plans — creates isolated git worktrees with smart directory selection and safety verification"
metadata:
  sources:
    - kind: github-file
      repo: obra/superpowers
      path: skills/using-git-worktrees/SKILL.md
      commit: 1128a721ca3b7fd76bf12e8392cdeb89cfcfcf2a
      attribution: Jesse Vincent
      license: MIT
      usage: referenced
---

Creates isolated git worktrees with smart directory selection, safety verification (checks gitignore), auto-detects project setup (npm, cargo, poetry, go), and verifies clean test baseline.
