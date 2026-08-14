#!/usr/bin/env ruby
# frozen_string_literal: true

# Trail of Bits Security — a team of agents, ported from paperclipai/companies
# (companies/trail-of-bits-security).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo
#   ├─► chaos-agent  (let-fate-decide)
#   ├─► chief-security-officer
#   │   ├─► audit-lead
#   │   │   ├─► burpsuite-analyst  (burpsuite-project-parser)
#   │   │   ├─► code-auditor  (agentic-actions-auditor, audit-context-building, sharp-edges, insecure-defaults, differential-review)
#   │   │   ├─► false-positive-analyst  (fp-check)
#   │   │   ├─► static-analysis-engineer  (static-analysis)
#   │   │   ├─► supply-chain-auditor  (supply-chain-risk-auditor)
#   │   │   ├─► testing-specialist  (testing-handbook-skills)
#   │   │   └─► variant-analyst  (variant-analysis, semgrep-rule-creator, semgrep-rule-variant-creator)
#   │   ├─► blockchain-security-lead
#   │   │   ├─► contract-entry-point-analyst  (entry-point-analyzer)
#   │   │   └─► smart-contract-auditor  (building-secure-contracts)
#   │   ├─► engineering-lead
#   │   │   ├─► infrastructure-engineer  (debug-buttercup, claude-in-chrome-troubleshooting)
#   │   │   ├─► skill-developer  (skill-improver, workflow-skill-design, ask-questions-if-underspecified, second-opinion)
#   │   │   └─► tooling-engineer  (gh-cli, git-cleanup, modern-python, devcontainer-setup, seatbelt-sandboxer)
#   │   ├─► reverse-engineering-lead
#   │   │   ├─► binary-analyst  (dwarf-expert)
#   │   │   ├─► malware-analyst  (yara-authoring)
#   │   │   └─► mobile-security-analyst  (firebase-apk-scanner)
#   │   └─► verification-lead
#   │       ├─► constant-time-analyst  (constant-time-analysis)
#   │       ├─► property-tester  (property-based-testing)
#   │       ├─► spec-compliance-analyst  (spec-to-code-compliance)
#   │       └─► zeroize-auditor  (zeroize-audit)
#   └─► culture-analyst  (culture-index)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/trail-of-bits-security/team.rb \
#     "<task for the team>"

require "bundler/setup"
require "brute"

MODEL = "claude-sonnet-4-20250514"

# Strip YAML frontmatter from an upstream markdown file, returning
# [frontmatter_hash, body].
def load_agent_md(path)
  raw = File.read(path)
  parts = raw.split(/^---\s*$/, 3)
  [YAML.safe_load(parts[1]), parts[2].strip]
end

def agent_dir(name) = File.join(__dir__, "agents", name)

# Build one team member as a SubAgent: verbatim AGENTS.md body as its
# system prompt, its own skills dir, the working tools, and its direct
# reports (if any) as callable sub-agents.
def member(name, description, reports: [])
  _meta, body = load_agent_md(File.join(agent_dir(name), "AGENTS.md"))

  prompt = Brute::SystemPrompt.build do |p, ctx|
    p << body
    skills = Brute::Prompts::Skills.call(ctx.merge(cwd: agent_dir(name)))
    p << skills if skills
    unless reports.empty?
      p << "Your direct reports are available as tools — call one to " \
           "delegate, passing the full task context."
    end
  end

  Brute::Tools::SubAgent.new(
    name:        name,
    description: description,
    provider:    Brute.provider,
    model:       MODEL,
    tools:       Brute::Tools::ALL + reports,
  ) do
    use Brute::Middleware::EventHandler,
        handler_class: Brute::Events::PrefixedTerminalOutput, prefix: name
    use Brute::Middleware::SystemPrompt, system_prompt: prompt
    use Brute::Middleware::ToolResultLoop
    use Brute::Middleware::MaxIterations
    use Brute::Middleware::ToolCall
    run Brute::Middleware::Completion::RubyLLM.new
  end
end

# The org chart, leaves first, so each manager can reference its reports.
# Descriptions come from each agent's "Where work comes from" /
# "What triggers you" section (or its opening paragraph).
chaos_agent = member("chaos-agent",
           "Chaos Agent — You are activated when a decision is deadlocked, when a " \
           "prompt is too vague to act on, when the team needs to break out of " \
           "conventional thinking, or when someone invokes heart-of-the-cards " \
           "energy.")

burpsuite_analyst = member("burpsuite-analyst",
           "Web Application Security Analyst — You are activated when a web " \
           "application audit involves Burp Suite testing data, when .burp project " \
           "files need analysis, or when HTTP traffic patterns need security review.")

code_auditor = member("code-auditor",
           "Senior Code Auditor — You are activated when a codebase needs manual " \
           "security review, when a differential review is needed for recent " \
           "changes, or when agentic AI workflows need security auditing.")

false_positive_analyst = member("false-positive-analyst",
           "False Positive Analyst — You are activated when findings need " \
           "verification before inclusion in a final report, when static analysis " \
           "produces results that need human validation, or when there is " \
           "disagreement about whether a finding is genuine.")

static_analysis_engineer = member("static-analysis-engineer",
           "Static Analysis Engineer — You are activated when an audit requires " \
           "automated vulnerability scanning, when SARIF results need parsing and " \
           "triage, or when the team needs custom static analysis queries for a " \
           "specific engagement.")

supply_chain_auditor = member("supply-chain-auditor",
           "Supply Chain Auditor — You are activated when an audit engagement " \
           "includes dependency analysis, when a project has a large or unusual " \
           "dependency tree, or when a supply chain compromise is suspected.")

testing_specialist = member("testing-specialist",
           "Application Security Testing Specialist — You are activated when an " \
           "audit engagement requires fuzzing, when test harnesses need writing, " \
           "when coverage analysis is needed, or when any testing methodology from " \
           "the appsec.guide handbook applies.")

variant_analyst = member("variant-analyst",
           "Variant Analyst — You are activated when a confirmed vulnerability needs " \
           "variant analysis, when an auditor identifies a bug class that may have " \
           "multiple instances, or when a Semgrep rule needs to be created or " \
           "adapted for a new language.")

audit_lead = member("audit-lead",
           "Audit Lead — You are activated when the CSO assigns an application " \
           "security audit, when audit team members need coordination, or when " \
           "findings need to be triaged and prioritized before report compilation.",
           reports: [burpsuite_analyst, code_auditor, false_positive_analyst, static_analysis_engineer, supply_chain_auditor, testing_specialist, variant_analyst])

contract_entry_point_analyst = member("contract-entry-point-analyst",
           "Contract Entry Point Analyst — You are activated at the start of every " \
           "smart contract audit to produce the initial attack surface map, or when " \
           "the audit team needs to verify they have complete coverage of externally " \
           "callable functions.")

smart_contract_auditor = member("smart-contract-auditor",
           "Senior Smart Contract Auditor — You are activated when a smart contract " \
           "codebase needs security review, when a blockchain protocol audit " \
           "requires contract-level analysis, or when development teams need " \
           "guidance on secure smart contract patterns.")

blockchain_security_lead = member("blockchain-security-lead",
           "Blockchain Security Lead — You are activated when the CSO assigns a " \
           "blockchain-related audit engagement, when smart contract findings need " \
           "technical review, or when a new blockchain platform requires assessment " \
           "methodology development.",
           reports: [contract_entry_point_analyst, smart_contract_auditor])

infrastructure_engineer = member("infrastructure-engineer",
           "Infrastructure Engineer — You are activated when Kubernetes deployments " \
           "need debugging, when MCP extension connectivity issues arise, or when " \
           "operational infrastructure needs maintenance.")

skill_developer = member("skill-developer",
           "Skill Developer — You are activated when a new skill needs to be " \
           "created, when existing skills need improvement, when workflow designs " \
           "need review, or when ambiguous requirements need clarification before " \
           "implementation.")

tooling_engineer = member("tooling-engineer",
           "Tooling Engineer — You are activated when a team needs a new tool, when " \
           "development environments need configuration, when Git workflows need " \
           "cleanup, or when applications need sandboxing configurations.")

engineering_lead = member("engineering-lead",
           "Engineering Lead — You are activated when audit teams need custom " \
           "tooling, when internal infrastructure requires maintenance, when " \
           "development environments need setup, or when engineering best practices " \
           "need to be established or updated.",
           reports: [infrastructure_engineer, skill_developer, tooling_engineer])

binary_analyst = member("binary-analyst",
           "Binary Analysis Specialist — You are activated when a compiled binary " \
           "needs security analysis, when debugging information needs " \
           "interpretation, when source-to-binary correspondence needs verification, " \
           "or when the compiled output must be examined to confirm source-level " \
           "security properties.")

malware_analyst = member("malware-analyst",
           "Malware Analyst — You are activated when detection rules are needed for " \
           "a threat, when a suspicious binary needs analysis, or when an engagement " \
           "requires custom detection capabilities.")

mobile_security_analyst = member("mobile-security-analyst",
           "Mobile Security Analyst — You are activated when a mobile application " \
           "needs security assessment, when Android APKs need scanning for Firebase " \
           "misconfigurations, or when mobile app reverse engineering is required " \
           "for an engagement.")

reverse_engineering_lead = member("reverse-engineering-lead",
           "Reverse Engineering Lead — You are activated when an engagement involves " \
           "closed-source binaries, mobile application security, malware analysis, " \
           "or any target where source code is unavailable or insufficient.",
           reports: [binary_analyst, malware_analyst, mobile_security_analyst])

constant_time_analyst = member("constant-time-analyst",
           "Constant-Time Analysis Specialist — You are activated when cryptographic " \
           "implementations need timing side-channel analysis, when a compiler " \
           "optimization may have introduced variable-time behavior into " \
           "constant-time source code, or when a crypto library audit requires " \
           "timing guarantees.")

property_tester = member("property-tester",
           "Property-Based Testing Specialist — You are activated when code needs " \
           "testing beyond what example-based tests provide, when an implementation " \
           "must satisfy invariants across all inputs, or when smart contract " \
           "properties need empirical verification.")

spec_compliance_analyst = member("spec-compliance-analyst",
           "Specification Compliance Analyst — You are activated when a blockchain " \
           "protocol implementation needs verification against its specification, " \
           "when a cryptographic algorithm implementation must match a standard " \
           "(RFC, NIST, etc.), or when specification deviation is suspected.")

zeroize_auditor = member("zeroize-auditor",
           "Zeroization Audit Specialist — You are activated when cryptographic " \
           "libraries need zeroization auditing, when an application handles " \
           "sensitive credentials that must be wiped from memory, or when compiler " \
           "optimizations are suspected of removing zeroization code.")

verification_lead = member("verification-lead",
           "Verification & Formal Methods Lead — You are activated when an " \
           "engagement requires formal guarantees about code behavior, when " \
           "cryptographic implementations need timing side-channel analysis, or when " \
           "specification compliance must be verified against an implementation.",
           reports: [constant_time_analyst, property_tester, spec_compliance_analyst, zeroize_auditor])

chief_security_officer = member("chief-security-officer",
           "Chief Security Officer — You are activated when the CEO hands off a " \
           "scoped engagement, when a team lead escalates a critical finding, or " \
           "when cross-team coordination is required on a complex audit.",
           reports: [audit_lead, blockchain_security_lead, engineering_lead, reverse_engineering_lead, verification_lead])

culture_analyst = member("culture-analyst",
           "Culture Analyst — You are activated when Culture Index survey results " \
           "are available for interpretation, when leadership needs insight into " \
           "team composition, or when hiring decisions need cultural fit assessment.")

TEAM = [chaos_agent, chief_security_officer, culture_analyst].freeze

# The Chief Executive Officer's prompt is the company description (COMPANY.md body)
# plus its own AGENTS.md, both verbatim.
_company_meta, company_body = load_agent_md(File.join(__dir__, "COMPANY.md"))
_root_meta, root_body       = load_agent_md(File.join(agent_dir("ceo"), "AGENTS.md"))

ROOT_PROMPT = Brute::SystemPrompt.build do |p, ctx|
  p << company_body
  p << root_body
  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: agent_dir("ceo")))
  p << skills if skills
  p << "Your direct reports are available as tools — call one to delegate, " \
       "passing the full task context. Synthesize their results before " \
       "replying to the user."
end

root = Brute::Agent.new(
  provider: Brute.provider,
  model:    MODEL,
  tools:    TEAM,
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: ROOT_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

request = ARGV.join(" ")
request = "Introduce the team: who's on it and what can each member do?" if request.empty?

session = Brute::Session.new
session.user(request)
root.call(session)
