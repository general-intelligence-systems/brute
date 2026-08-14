---
name: Aeon Intelligence
description: Autonomous AI intelligence company powered by Aeon — runs research, engineering, crypto monitoring, and productivity workflows on GitHub Actions via Claude Code
slug: aeon-intelligence
schema: agentcompanies/v1
version: 0.1.0
license: MIT
goals:
  - Deliver autonomous research digests, code reviews, and on-chain alerts on scheduled cadences
  - Maintain a living memory system that evolves with each run
  - Operate entirely on GitHub Actions with zero infrastructure overhead
---

Aeon Intelligence is an autonomous AI company built on the [Aeon](https://github.com/aaronjmars/aeon) platform. It runs 32 skills across research, engineering, crypto, and productivity domains — all powered by Claude Code executing on GitHub Actions.

## How it works

The company operates on a **hub-and-spoke** model. The CEO (Chief Intelligence Officer) orchestrates daily and weekly rhythms, while three specialist agents run domain-specific pipelines autonomously on cron schedules. Agents write results to the repo, maintain shared memory, and notify the user via Telegram, Discord, or Slack.

## Workflow

1. Skills fire on their configured cron schedules (or on-demand via messages)
2. Each agent executes its assigned skills, writes outputs to the repo, and logs activity to memory
3. The CEO synthesizes results into morning briefs and weekly reviews
4. Users interact via messaging channels; messages are routed to the appropriate agent
5. Meta skills (heartbeat, reflect, memory-flush) keep the system healthy and self-aware

Generated from [aeon](https://github.com/aaronjmars/aeon) with the company-creator skill from [Paperclip](https://github.com/paperclipai/paperclip)
