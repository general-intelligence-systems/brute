---
name: RedOak Review
description: A boutique code quality, design, and security review agency powered by pragmatic, opinionated review workflows
slug: redoak-review
schema: agentcompanies/v1
version: 1.0.0
license: MIT
authors:
  - name: Patrick Ellis
goals:
  - Deliver expert-level code, design, and security reviews with structured methodology
  - Balance engineering rigor with development speed using pragmatic quality frameworks
  - Automate review pipelines through GitHub Actions integration
---

RedOak Review is a focused review agency with three specialties: code quality, UI/UX design, and security. Each reviewer uses a structured, opinionated framework with clear triage levels.

## How Work Flows

1. **Lead Reviewer** receives a review request (PR, branch, or codebase), determines what kind of review is needed, and dispatches to the right specialist
2. **Code Reviewer** performs a 7-tier pragmatic quality analysis — from architecture down to documentation
3. **Design Reviewer** runs an 8-phase live-browser design review using Playwright, testing across viewports
4. **Security Reviewer** conducts a 3-phase security analysis with strict confidence thresholds (>80%) to minimize false positives
5. **CI Integration Engineer** maintains GitHub Actions pipelines that automate all three review types on every PR

---

Generated from [claude-code-workflows](https://github.com/OneRedOak/claude-code-workflows) with the company-creator skill from [Paperclip](https://github.com/paperclipai/paperclip)
