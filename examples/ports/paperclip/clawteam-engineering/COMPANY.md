---
name: ClawTeam Engineering
description: Agentic software engineering through self-organizing multi-agent teams that plan, build, review, test, and deploy software autonomously
slug: clawteam-engineering
schema: agentcompanies/v1
version: 0.1.0
license: MIT
goals:
  - Build and ship software through autonomous agent coordination
  - Maintain high code quality through systematic review and testing
  - Enable parallel development with conflict-free git worktree isolation
---

ClawTeam Engineering builds software through self-organizing agent teams. The CEO (Tech Lead) coordinates a pipeline of specialists — backend developer, frontend developer, QA engineer, and DevOps engineer — who work in parallel where possible and hand off through ClawTeam's task and messaging system.

Work flows as a pipeline with a parallel middle stage: the CEO decomposes requirements into dependency-aware tasks, Backend and Frontend Developers implement in isolated git worktrees simultaneously, the QA Engineer reviews and tests completed work, and the DevOps Engineer handles deployment. Agents coordinate through ClawTeam's task dependencies (blocking chains ensure correct ordering) and mailbox messaging (for real-time coordination).

Generated from [ClawTeam](https://github.com/HKUDS/ClawTeam) with the company-creator skill from [Paperclip](https://github.com/paperclipai/paperclip)
