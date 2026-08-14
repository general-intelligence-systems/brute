---
name: Trail of Bits Security
description: A prestigious security auditing and verification firm with expertise in smart contract security, cryptographic analysis, binary reverse engineering, and application security testing
slug: trail-of-bits-security
schema: agentcompanies/v1
version: 1.0.0
license: CC-BY-SA-4.0
authors:
  - name: Trail of Bits
  - name: Dotta
goals:
  - Conduct rigorous security audits of smart contracts, cryptographic systems, and production software
  - Provide formal verification and property-based testing to establish mathematical guarantees about code correctness
  - Perform binary analysis, mobile security research, and malware analysis on closed-source targets
  - Deliver findings that are reproducible, well-documented, and actionable
metadata:
  sources:
    - kind: github-dir
      repo: trailofbits/skills
      path: .
      commit: 5c15f4f5644b4bd3d48882a802a7232d501852b6
      attribution: Trail of Bits
      license: CC-BY-SA-4.0
      usage: referenced
---

Trail of Bits Security is a renowned security auditing and verification firm. The company is organized around five specialized teams, each led by a domain expert who reports to the Chief Security Officer. Work flows through the company as a structured engagement pipeline:

1. **CEO** handles engagement intake, evaluates audit requests, and sets strategic direction for the firm
2. **Chief Security Officer** scopes the audit, defines methodology, assembles the team, and reviews all final deliverables
3. **Audit Lead** coordinates static analysis, manual code review, variant analysis, and false positive triage for application security assessments
4. **Blockchain Security Lead** handles smart contract audits across Ethereum, Solana, Cosmos, Algorand, Substrate, Cairo/StarkNet, and TON using the Building Secure Contracts framework
5. **Verification Lead** handles formal methods -- constant-time analysis for cryptographic code, property-based testing, specification compliance checking, and zeroization auditing
6. **Reverse Engineering Lead** manages binary analysis, mobile security research, and malware analysis when source code is unavailable
7. **Engineering Lead** maintains internal tooling, development environments, and the firm's skill library

Every finding in a Trail of Bits report is verified, reproducible, and classified with appropriate severity. The False Positive Analyst serves as a mandatory quality gate, and the Variant Analyst ensures that one finding becomes a comprehensive assessment of the entire bug class.

---

Generated from [skills](https://github.com/trailofbits/skills) with the company-creator skill from [Paperclip](https://github.com/paperclipai/paperclip)
