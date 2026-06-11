# OpenFang-based agents

One example per agent in **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang/tree/main/agents)**.

Each `agent.rb` carries its manifest's system prompt verbatim and its original
temperature; manifest tool names map to brute tools through [`tools.rb`](tools.rb).
Agents are just prompt + tools — the architecture is the brute gem's.

| Agent | Description |
|-------|-------------|
| [analyst](analyst/agent.rb) | Data analyst. Processes data, generates insights, creates reports. |
| [architect](architect/agent.rb) | System architect. Designs software architectures, evaluates trade-offs, creates technical specifications. |
| [assistant](assistant/agent.rb) | General-purpose assistant agent. The default OpenClaw agent for everyday tasks, questions, and conversations. |
| [code-reviewer](code-reviewer/agent.rb) | Senior code reviewer. Reviews PRs, identifies issues, suggests improvements with production standards. |
| [coder](coder/agent.rb) | Expert software engineer. Reads, writes, and analyzes code. |
| [customer-support](customer-support/agent.rb) | Customer support agent for ticket handling, issue resolution, and customer communication. |
| [data-scientist](data-scientist/agent.rb) | Data scientist. Analyzes datasets, builds models, creates visualizations, performs statistical analysis. |
| [debugger](debugger/agent.rb) | Expert debugger. Traces bugs, analyzes stack traces, performs root cause analysis. |
| [devops-lead](devops-lead/agent.rb) | DevOps lead. Manages CI/CD, infrastructure, deployments, monitoring, and incident response. |
| [doc-writer](doc-writer/agent.rb) | Technical writer. Creates documentation, README files, API docs, tutorials, and architecture guides. |
| [email-assistant](email-assistant/agent.rb) | Email triage, drafting, scheduling, and inbox management agent. |
| [health-tracker](health-tracker/agent.rb) | Wellness tracking agent for health metrics, medication reminders, fitness goals, and lifestyle habits. |
| [hello-world](hello-world/agent.rb) | A friendly greeting agent that can read files, search the web, and answer everyday questions. |
| [home-automation](home-automation/agent.rb) | Smart home control agent for IoT device management, automation rules, and home monitoring. |
| [langchain-code-reviewer](langchain-code-reviewer/agent.rb) | A bilingual (中文 output) principal-level code review agent (LangChain port). |
| [legal-assistant](legal-assistant/agent.rb) | Legal assistant agent for contract review, legal research, compliance checking, and document drafting. |
| [meeting-assistant](meeting-assistant/agent.rb) | Meeting notes, action items, agenda preparation, and follow-up tracking agent. |
| [ops](ops/agent.rb) | DevOps agent. Monitors systems, runs diagnostics, manages deployments. |
| [orchestrator](orchestrator/agent.rb) | Meta-agent that decomposes complex tasks, delegates to specialist agents, and synthesizes results. |
| [personal-finance](personal-finance/agent.rb) | Personal finance agent for budget tracking, expense analysis, savings goals, and financial planning. |
| [planner](planner/agent.rb) | Project planner. Creates project plans, breaks down epics, estimates effort, identifies risks and dependencies. |
| [recruiter](recruiter/agent.rb) | Recruiting agent for resume screening, candidate outreach, job description writing, and hiring pipeline management. |
| [researcher](researcher/agent.rb) | Research agent. Fetches web content and synthesizes information. |
| [sales-assistant](sales-assistant/agent.rb) | Sales assistant agent for CRM updates, outreach drafting, pipeline management, and deal tracking. |
| [security-auditor](security-auditor/agent.rb) | Security specialist. Reviews code for vulnerabilities, checks configurations, performs threat modeling. |
| [social-media](social-media/agent.rb) | Social media content creation, scheduling, and engagement strategy agent. |
| [test-engineer](test-engineer/agent.rb) | Quality assurance engineer. Designs test strategies, writes tests, validates correctness. |
| [translator](translator/agent.rb) | Multi-language translation agent for document translation, localization, and cross-cultural communication. |
| [travel-planner](travel-planner/agent.rb) | Trip planning agent for itinerary creation, booking research, budget estimation, and travel logistics. |
| [tutor](tutor/agent.rb) | Teaching and explanation agent for learning, tutoring, and educational content creation. |
| [writer](writer/agent.rb) | Content writer. Creates documentation, articles, and technical writing. |
