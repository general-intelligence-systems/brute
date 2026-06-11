---
name: Superpowers Dev Shop
description: A disciplined software development company powered by the Superpowers workflow — brainstorm, plan, build with TDD, review, and ship
slug: superpowers
schema: agentcompanies/v1
version: 1.0.0
license: MIT
authors:
  - name: Jesse Vincent
goals:
  - Build software through disciplined, test-driven development
  - Enforce quality at every stage — design, implementation, review, and shipping
  - Use systematic workflows instead of ad-hoc development
---

Superpowers Dev Shop is a software development company that enforces a rigorous pipeline workflow. Every feature flows through brainstorming, planning, TDD implementation, code review, and verified shipping.

The company is built on the [Superpowers](https://github.com/obra/superpowers) skill library — a complete development methodology for coding agents that emphasizes test-driven development, systematic debugging, and disciplined collaboration.

## How Work Flows

1. **CEO** receives a feature idea and runs a brainstorming session to explore intent, requirements, and design. Once the design is approved, the CEO writes a detailed implementation plan with bite-sized tasks.
2. **Lead Engineer** picks up the plan, creates an isolated git worktree, and implements using strict TDD (red-green-refactor). Can dispatch parallel subagents for independent tasks and debugs issues systematically.
3. **Code Reviewer** reviews the implementation against the original plan, verifies correctness, and gates quality. Requests changes or approves.
4. **Release Engineer** takes approved code and handles the merge/PR decision, verifies the final state, and cleans up.

Generated from [superpowers](https://github.com/obra/superpowers) with the company-creator skill from [Paperclip](https://github.com/paperclipai/paperclip)
