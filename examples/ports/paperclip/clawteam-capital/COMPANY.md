---
name: ClawTeam Capital
description: AI-powered investment analysis through specialized multi-agent teams that research securities from multiple angles and consolidate signals into risk-adjusted portfolio decisions
slug: clawteam-capital
schema: agentcompanies/v1
version: 0.1.0
license: MIT
goals:
  - Conduct rigorous multi-perspective investment analysis
  - Produce risk-adjusted portfolio decisions with clear signal attribution
  - Maintain disciplined position sizing through systematic risk management
---

ClawTeam Capital is an AI-powered investment analysis firm that deploys specialized analyst teams to research securities from multiple angles. The CEO (Portfolio Manager) leads a hub-and-spoke organization of five specialist analysts and a Risk Manager, coordinating through ClawTeam's task and messaging system.

Work flows hub-and-spoke: the CEO receives an investment thesis or ticker and dispatches it to five analysts — value (Buffett-style), growth, technical, fundamentals, and sentiment — who research independently and report standardized signals (bullish/bearish/neutral with confidence scores). The Risk Manager consolidates all signals, applies volatility-adjusted position limits, and produces a risk assessment. The CEO synthesizes everything into a final investment decision.

Agents communicate via ClawTeam's mailbox system, enabling parallel independent research without interference.

Generated from [ClawTeam](https://github.com/HKUDS/ClawTeam) with the company-creator skill from [Paperclip](https://github.com/paperclipai/paperclip)
