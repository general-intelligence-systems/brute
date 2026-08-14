#!/usr/bin/env ruby
# frozen_string_literal: true

# Fullstack Forge — a team of agents, ported from paperclipai/companies
# (companies/fullstack-forge).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo  (feature-forge, spec-miner)
#   └─► cto  (architecture-designer, code-reviewer)
#       ├─► architecture-lead  (the-fool)
#       │   ├─► api-engineer  (api-designer, graphql-architect)
#       │   ├─► distributed-systems-engineer  (microservices-architect, websocket-engineer)
#       │   └─► mcp-engineer  (mcp-developer)
#       ├─► backend-lead  (the-fool)
#       │   ├─► enterprise-backend-engineer  (spring-boot-engineer, dotnet-core-expert)
#       │   ├─► node-backend-engineer  (nestjs-expert)
#       │   ├─► php-backend-engineer  (laravel-specialist)
#       │   ├─► python-backend-engineer  (django-expert, fastapi-expert)
#       │   └─► ruby-backend-engineer  (rails-expert)
#       ├─► data-lead  (the-fool)
#       │   ├─► ai-engineer  (prompt-engineer, rag-architect)
#       │   ├─► data-engineer  (pandas-pro, spark-engineer)
#       │   └─► ml-engineer  (ml-pipeline, fine-tuning-expert)
#       ├─► devops-lead  (debugging-wizard)
#       │   ├─► devops-engineer  (devops-engineer, cli-developer)
#       │   └─► sre-engineer  (sre-engineer, monitoring-expert, chaos-engineer)
#       ├─► embedded-systems-engineer  (embedded-systems)
#       ├─► frontend-lead  (debugging-wizard)
#       │   ├─► angular-engineer  (angular-architect)
#       │   ├─► mobile-engineer  (react-native-expert, flutter-expert)
#       │   ├─► react-engineer  (react-expert, nextjs-developer)
#       │   └─► vue-engineer  (vue-expert, vue-expert-js)
#       ├─► game-developer  (game-developer)
#       ├─► infrastructure-lead  (the-fool)
#       │   ├─► cloud-engineer  (cloud-architect, terraform-engineer)
#       │   ├─► database-engineer  (postgres-pro, database-optimizer, sql-pro)
#       │   └─► kubernetes-engineer  (kubernetes-specialist)
#       ├─► language-engineering-lead  (debugging-wizard)
#       │   ├─► go-engineer  (golang-pro)
#       │   ├─► jvm-engineer  (java-architect, kotlin-specialist)
#       │   ├─► mobile-language-engineer  (swift-expert)
#       │   ├─► python-engineer  (python-pro)
#       │   ├─► rust-engineer  (rust-engineer)
#       │   ├─► systems-language-engineer  (cpp-pro, csharp-developer)
#       │   ├─► typescript-engineer  (typescript-pro, javascript-pro)
#       │   └─► web-language-engineer  (php-pro)
#       ├─► legacy-modernization-specialist  (legacy-modernizer)
#       ├─► platform-lead  (debugging-wizard)
#       │   ├─► atlassian-engineer  (atlassian-mcp)
#       │   ├─► ecommerce-engineer  (shopify-expert, wordpress-pro)
#       │   └─► salesforce-developer  (salesforce-developer)
#       ├─► qa-lead  (debugging-wizard)
#       │   ├─► code-quality-specialist  (code-reviewer, code-documenter)
#       │   └─► test-engineer  (test-master, playwright-expert)
#       └─► security-lead  (debugging-wizard)
#           └─► security-engineer  (secure-code-guardian, security-reviewer, fullstack-guardian)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/fullstack-forge/team.rb \
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
api_engineer = member("api-engineer",
           "Senior API/GraphQL Engineer — You are activated when a task requires API " \
           "design, OpenAPI specifications, GraphQL schemas, or Apollo Federation.")

distributed_systems_engineer = member("distributed-systems-engineer",
           "Senior Distributed Systems Engineer — You are activated when a task " \
           "requires distributed system design, monolith decomposition, or real-time " \
           "WebSocket communication.")

mcp_engineer = member("mcp-engineer",
           "Senior MCP Developer — You are activated when a task requires building, " \
           "debugging, or extending MCP servers or clients.")

architecture_lead = member("architecture-lead",
           "Director of API & Architecture — You are activated when the CTO routes " \
           "API design, distributed systems, or MCP integration work to your " \
           "department.",
           reports: [api_engineer, distributed_systems_engineer, mcp_engineer])

enterprise_backend_engineer = member("enterprise-backend-engineer",
           "Senior Spring Boot/.NET Engineer — You are activated when a task " \
           "requires enterprise Java or .NET backend services.")

node_backend_engineer = member("node-backend-engineer",
           "Senior NestJS Engineer — You are activated when a task requires building " \
           "enterprise-grade TypeScript backend applications with NestJS.")

php_backend_engineer = member("php-backend-engineer",
           "Senior Laravel Engineer — You are activated when a task requires Laravel " \
           "10+ applications with Eloquent, Sanctum, Horizon, or Livewire.")

python_backend_engineer = member("python-backend-engineer",
           "Senior Django/FastAPI Engineer — You are activated when a task requires " \
           "Python web applications or async APIs using Django or FastAPI.")

ruby_backend_engineer = member("ruby-backend-engineer",
           "Senior Rails Engineer — You are activated when a task requires Rails 7+ " \
           "web applications with Hotwire, real-time features, or background jobs.")

backend_lead = member("backend-lead",
           "Director of Backend Engineering — You are activated when the CTO routes " \
           "backend API or service work to your department.",
           reports: [enterprise_backend_engineer, node_backend_engineer, php_backend_engineer, python_backend_engineer, ruby_backend_engineer])

ai_engineer = member("ai-engineer",
           "Senior AI Engineer — You are activated when a task requires LLM prompt " \
           "design, RAG system architecture, or AI application development.")

data_engineer = member("data-engineer",
           "Senior Data Engineer — You are activated when a task requires DataFrame " \
           "operations, data transformation, distributed data processing, or big " \
           "data workloads.")

ml_engineer = member("ml-engineer",
           "Senior ML Engineer — You are activated when a task requires ML pipeline " \
           "infrastructure, experiment tracking, model fine-tuning, or MLOps " \
           "tooling.")

data_lead = member("data-lead",
           "Director of Data & ML — You are activated when the CTO routes data " \
           "processing, machine learning, or AI work to your department.",
           reports: [ai_engineer, data_engineer, ml_engineer])

devops_engineer = member("devops-engineer",
           "Senior DevOps Engineer — You are activated when a task requires " \
           "Dockerfiles, CI/CD pipeline configuration, Kubernetes manifests, " \
           "infrastructure templates, or CLI tool development.")

sre_engineer = member("sre-engineer",
           "Senior Site Reliability Engineer — You are activated when a task " \
           "requires SLO definition, monitoring setup, incident response design, or " \
           "chaos engineering.")

devops_lead = member("devops-lead",
           "Director of DevOps & SRE — You are activated when the CTO routes CI/CD, " \
           "deployment, monitoring, or reliability work to your department.",
           reports: [devops_engineer, sre_engineer])

embedded_systems_engineer = member("embedded-systems-engineer",
           "Senior Embedded Systems Engineer — You are activated when a task " \
           "requires firmware development, RTOS applications, or microcontroller " \
           "programming.")

angular_engineer = member("angular-engineer",
           "Senior Angular Engineer — You are activated when a task requires Angular " \
           "17+ applications with standalone components, NgRx, or signals.")

mobile_engineer = member("mobile-engineer",
           "Senior Mobile Engineer — You are activated when a task requires " \
           "cross-platform mobile apps with React Native/Expo or Flutter.")

react_engineer = member("react-engineer",
           "Senior React/Next.js Engineer — You are activated when a task requires " \
           "React 18+ applications or Next.js 14+ projects with App Router.")

vue_engineer = member("vue-engineer",
           "Senior Vue.js Engineer — You are activated when a task requires Vue 3 " \
           "applications, Nuxt 3 SSR/SSG, or Quasar/Capacitor mobile apps.")

frontend_lead = member("frontend-lead",
           "Director of Frontend & Mobile — You are activated when the CTO routes " \
           "frontend UI, mobile app, or client-side work to your department.",
           reports: [angular_engineer, mobile_engineer, react_engineer, vue_engineer])

game_developer = member("game-developer",
           "Senior Game Developer — You are activated when a task requires game " \
           "system development with Unity or Unreal Engine.")

cloud_engineer = member("cloud-engineer",
           "Senior Cloud Architect — You are activated when a task requires cloud " \
           "architecture design, migration planning, cost optimization, or Terraform " \
           "IaC.")

database_engineer = member("database-engineer",
           "Senior Database Engineer — You are activated when a task requires " \
           "PostgreSQL configuration, SQL query optimization, schema design, or " \
           "database performance tuning across any dialect.")

kubernetes_engineer = member("kubernetes-engineer",
           "Senior Kubernetes Engineer — You are activated when a task requires " \
           "Kubernetes deployment, Helm charts, RBAC, or cluster management.")

infrastructure_lead = member("infrastructure-lead",
           "Director of Infrastructure & Cloud — You are activated when the CTO " \
           "routes infrastructure, cloud, or database work to your department.",
           reports: [cloud_engineer, database_engineer, kubernetes_engineer])

go_engineer = member("go-engineer",
           "Senior Go Engineer — You are activated when a task requires Go " \
           "development including concurrent programming, microservices, or " \
           "high-performance systems.")

jvm_engineer = member("jvm-engineer",
           "Senior Java/Kotlin Engineer — You are activated when a task requires " \
           "enterprise Java with Spring Boot 3.x, Kotlin applications with " \
           "coroutines, or multiplatform development.")

mobile_language_engineer = member("mobile-language-engineer",
           "Senior Swift Engineer — You are activated when a task requires native " \
           "iOS/macOS/watchOS/tvOS development with Swift 5.9+.")

python_engineer = member("python-engineer",
           "Senior Python Engineer — You are activated when a task requires Python " \
           "3.11+ development including type-safe applications, async programming, " \
           "or robust error handling.")

rust_engineer = member("rust-engineer",
           "Senior Rust Engineer — You are activated when a task requires Rust " \
           "development with memory safety, zero-cost abstractions, or systems " \
           "programming.")

systems_language_engineer = member("systems-language-engineer",
           "Senior C++/C# Engineer — You are activated when a task requires C++20/23 " \
           "development, .NET 8+ applications, ASP.NET Core APIs, or Blazor web " \
           "apps.")

typescript_engineer = member("typescript-engineer",
           "Senior TypeScript/JavaScript Engineer — You are activated when a task " \
           "requires TypeScript type system expertise, JavaScript ES2023+ " \
           "development, or full-stack type safety with tRPC.")

web_language_engineer = member("web-language-engineer",
           "Senior PHP Engineer — You are activated when a task requires PHP 8.3+ " \
           "development with strict typing, PHPStan, async patterns with Swoole, or " \
           "PSR standards.")

language_engineering_lead = member("language-engineering-lead",
           "Director of Language Engineering — You are activated when the CTO routes " \
           "language-specific implementation work to your department, or when a " \
           "project needs a particular language expert.",
           reports: [go_engineer, jvm_engineer, mobile_language_engineer, python_engineer, rust_engineer, systems_language_engineer, typescript_engineer, web_language_engineer])

legacy_modernization_specialist = member("legacy-modernization-specialist",
           "Senior Legacy Modernization Engineer — You are activated when a project " \
           "involves modernizing legacy systems, migrating aging codebases, or " \
           "decomposing monoliths.")

atlassian_engineer = member("atlassian-engineer",
           "Senior Atlassian Engineer — You are activated when a task requires Jira " \
           "issue management, Confluence page editing, sprint management, or " \
           "Atlassian MCP integration.")

ecommerce_engineer = member("ecommerce-engineer",
           "Senior E-Commerce Engineer — You are activated when a task requires " \
           "Shopify theme development, custom Shopify apps, WordPress themes, " \
           "plugins, or WooCommerce stores.")

salesforce_developer = member("salesforce-developer",
           "Senior Salesforce Developer — You are activated when a task requires " \
           "Apex code, Lightning Web Components, SOQL optimization, triggers, or " \
           "Salesforce DX.")

platform_lead = member("platform-lead",
           "Director of Platform Specialists — You are activated when the CTO routes " \
           "Salesforce, e-commerce, or Atlassian platform work to your department.",
           reports: [atlassian_engineer, ecommerce_engineer, salesforce_developer])

code_quality_specialist = member("code-quality-specialist",
           "Senior Code Quality Engineer — You are activated when code needs review " \
           "for bugs, security, or quality, or when technical documentation needs to " \
           "be created.")

test_engineer = member("test-engineer",
           "Senior Test Engineer — You are activated when a task requires unit " \
           "tests, integration tests, E2E tests, performance tests, or test " \
           "architecture design.")

qa_lead = member("qa-lead",
           "Director of Quality & Testing — You are activated when the CTO routes " \
           "testing, code review, or quality assurance work to your department, or " \
           "when any team needs QA support.",
           reports: [code_quality_specialist, test_engineer])

security_engineer = member("security-engineer",
           "Senior Security Engineer — You are activated when a task requires " \
           "authentication implementation, security hardening, vulnerability " \
           "auditing, or secure full-stack development.")

security_lead = member("security-lead",
           "Director of Security — You are activated when the CTO routes security " \
           "work to your department, or when any team needs a security review.",
           reports: [security_engineer])

cto = member("cto",
           "Chief Technology Officer — You are activated when the CEO hands you a " \
           "scoped project, or when a technical decision needs to be made about " \
           "architecture, team assignment, or code quality.",
           reports: [architecture_lead, backend_lead, data_lead, devops_lead, embedded_systems_engineer, frontend_lead, game_developer, infrastructure_lead, language_engineering_lead, legacy_modernization_specialist, platform_lead, qa_lead, security_lead])

TEAM = [cto].freeze

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
