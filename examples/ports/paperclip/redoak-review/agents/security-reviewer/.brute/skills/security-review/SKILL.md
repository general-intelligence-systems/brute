---
name: security-review
description: >
  Perform a focused 3-phase security review with vulnerability identification, false-positive filtering, and confidence scoring (>80% exploitability threshold) covering Input Validation, Auth, Crypto, Injection, and Data Exposure
metadata:
  sources:
    - kind: github-file
      repo: OneRedOak/claude-code-workflows
      path: security-review/security-review-slash-command.md
      commit: 6a653445125da828f31af473fcdd3cf29f99be82
      attribution: Patrick Ellis
      license: MIT
      usage: referenced
---

Perform a focused security review using a 3-phase methodology: vulnerability identification across five domains (Input Validation, Authentication/Authorization, Cryptography, Injection, Data Exposure), aggressive false-positive filtering, and confidence scoring with an 80% exploitability threshold. Only reports findings the reviewer is confident are real and exploitable. Use when reviewing code for security vulnerabilities, auditing authentication flows, or assessing data handling practices.
