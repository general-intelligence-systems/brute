---
name: design-review
description: >
  Perform a comprehensive 8-phase UI/UX design review covering Preparation, Interaction, Responsiveness, Visual Polish, Accessibility, Robustness, Code Health, and Content across 1440px, 768px, and 375px viewports using Playwright
metadata:
  sources:
    - kind: github-file
      repo: OneRedOak/claude-code-workflows
      path: design-review/design-review-agent.md
      commit: 6a653445125da828f31af473fcdd3cf29f99be82
      attribution: Patrick Ellis
      license: MIT
      usage: referenced
---

Perform a comprehensive UI/UX design review using an 8-phase methodology: Preparation, Interaction, Responsiveness, Visual Polish, Accessibility, Robustness, Code Health, and Content. Tests at three viewport breakpoints (1440px, 768px, 375px) and uses Playwright MCP for live browser testing when available. Use when reviewing frontend changes, deployed UIs, or design implementations.
