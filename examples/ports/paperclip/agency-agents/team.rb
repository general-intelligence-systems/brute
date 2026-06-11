#!/usr/bin/env ruby
# frozen_string_literal: true

# Agency Agents — a team of agents, ported from paperclipai/companies
# (companies/agency-agents).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo
#   ├─► chief-of-staff
#   │   ├─► academic-anthropologist
#   │   ├─► academic-geographer
#   │   ├─► academic-historian
#   │   ├─► academic-narratologist
#   │   ├─► academic-psychologist
#   │   ├─► accounts-payable-agent
#   │   ├─► agentic-identity-trust
#   │   ├─► agents-orchestrator
#   │   ├─► automation-governance-architect
#   │   ├─► blockchain-security-auditor
#   │   ├─► compliance-auditor
#   │   ├─► corporate-training-designer
#   │   ├─► data-consolidation-agent
#   │   ├─► government-digital-presales-consultant
#   │   ├─► healthcare-marketing-compliance
#   │   ├─► identity-graph-operator
#   │   ├─► lsp-index-engineer
#   │   ├─► recruitment-specialist
#   │   ├─► report-distribution-agent
#   │   ├─► sales-data-extraction-agent
#   │   ├─► specialized-cultural-intelligence-strategist
#   │   ├─► specialized-developer-advocate
#   │   ├─► specialized-document-generator
#   │   ├─► specialized-french-consulting-market
#   │   ├─► specialized-korean-business-navigator
#   │   ├─► specialized-mcp-builder
#   │   ├─► specialized-model-qa
#   │   ├─► specialized-salesforce-architect
#   │   ├─► specialized-workflow-architect
#   │   ├─► study-abroad-advisor
#   │   ├─► supply-chain-strategist
#   │   └─► zk-steward
#   ├─► cmo
#   │   ├─► marketing-ai-citation-strategist
#   │   ├─► marketing-app-store-optimizer
#   │   ├─► marketing-baidu-seo-specialist
#   │   ├─► marketing-bilibili-content-strategist
#   │   ├─► marketing-book-co-author
#   │   ├─► marketing-carousel-growth-engine
#   │   ├─► marketing-china-ecommerce-operator
#   │   ├─► marketing-content-creator
#   │   ├─► marketing-cross-border-ecommerce
#   │   ├─► marketing-douyin-strategist
#   │   ├─► marketing-growth-hacker
#   │   ├─► marketing-instagram-curator
#   │   ├─► marketing-kuaishou-strategist
#   │   ├─► marketing-linkedin-content-creator
#   │   ├─► marketing-livestream-commerce-coach
#   │   ├─► marketing-podcast-strategist
#   │   ├─► marketing-private-domain-operator
#   │   ├─► marketing-reddit-community-builder
#   │   ├─► marketing-seo-specialist
#   │   ├─► marketing-short-video-editing-coach
#   │   ├─► marketing-social-media-strategist
#   │   ├─► marketing-tiktok-strategist
#   │   ├─► marketing-twitter-engager
#   │   ├─► marketing-wechat-official-account
#   │   ├─► marketing-weibo-strategist
#   │   ├─► marketing-xiaohongshu-specialist
#   │   ├─► marketing-zhihu-strategist
#   │   ├─► paid-media-auditor
#   │   ├─► paid-media-creative-strategist
#   │   ├─► paid-media-paid-social-strategist
#   │   ├─► paid-media-ppc-strategist
#   │   ├─► paid-media-programmatic-buyer
#   │   ├─► paid-media-search-query-analyst
#   │   └─► paid-media-tracking-specialist
#   ├─► creative-director
#   │   ├─► design-brand-guardian
#   │   ├─► design-image-prompt-engineer
#   │   ├─► design-inclusive-visuals-specialist
#   │   ├─► design-ui-designer
#   │   ├─► design-ux-architect
#   │   ├─► design-ux-researcher
#   │   ├─► design-visual-storyteller
#   │   └─► design-whimsy-injector
#   ├─► game-dev-director
#   │   ├─► blender-addon-engineer
#   │   ├─► game-audio-engineer
#   │   ├─► game-designer
#   │   ├─► godot-gameplay-scripter
#   │   ├─► godot-multiplayer-engineer
#   │   ├─► godot-shader-developer
#   │   ├─► level-designer
#   │   ├─► narrative-designer
#   │   ├─► roblox-avatar-creator
#   │   ├─► roblox-experience-designer
#   │   ├─► roblox-systems-scripter
#   │   ├─► technical-artist
#   │   ├─► unity-architect
#   │   ├─► unity-editor-tool-developer
#   │   ├─► unity-multiplayer-engineer
#   │   ├─► unity-shader-graph-artist
#   │   ├─► unreal-multiplayer-architect
#   │   ├─► unreal-systems-engineer
#   │   ├─► unreal-technical-artist
#   │   └─► unreal-world-builder
#   ├─► vp-engineering
#   │   ├─► engineering-ai-data-remediation-engineer
#   │   ├─► engineering-ai-engineer
#   │   ├─► engineering-autonomous-optimization-architect
#   │   ├─► engineering-backend-architect
#   │   ├─► engineering-code-reviewer
#   │   ├─► engineering-data-engineer
#   │   ├─► engineering-database-optimizer
#   │   ├─► engineering-devops-automator
#   │   ├─► engineering-embedded-firmware-engineer
#   │   ├─► engineering-feishu-integration-developer
#   │   ├─► engineering-frontend-developer
#   │   ├─► engineering-git-workflow-master
#   │   ├─► engineering-incident-response-commander
#   │   ├─► engineering-mobile-app-builder
#   │   ├─► engineering-rapid-prototyper
#   │   ├─► engineering-security-engineer
#   │   ├─► engineering-senior-developer
#   │   ├─► engineering-software-architect
#   │   ├─► engineering-solidity-smart-contract-engineer
#   │   ├─► engineering-sre
#   │   ├─► engineering-technical-writer
#   │   ├─► engineering-threat-detection-engineer
#   │   ├─► engineering-wechat-mini-program-developer
#   │   ├─► qa-director
#   │   │   ├─► testing-accessibility-auditor
#   │   │   ├─► testing-api-tester
#   │   │   ├─► testing-evidence-collector
#   │   │   ├─► testing-performance-benchmarker
#   │   │   ├─► testing-reality-checker
#   │   │   ├─► testing-test-results-analyzer
#   │   │   ├─► testing-tool-evaluator
#   │   │   └─► testing-workflow-optimizer
#   │   └─► xr-director
#   │       ├─► macos-spatial-metal-engineer
#   │       ├─► terminal-integration-specialist
#   │       ├─► visionos-spatial-engineer
#   │       ├─► xr-cockpit-interaction-specialist
#   │       ├─► xr-immersive-developer
#   │       └─► xr-interface-architect
#   ├─► vp-operations
#   │   ├─► support-analytics-reporter
#   │   ├─► support-executive-summary-generator
#   │   ├─► support-finance-tracker
#   │   ├─► support-infrastructure-maintainer
#   │   ├─► support-legal-compliance-checker
#   │   └─► support-support-responder
#   ├─► vp-product
#   │   ├─► product-behavioral-nudge-engine
#   │   ├─► product-feedback-synthesizer
#   │   ├─► product-manager
#   │   ├─► product-sprint-prioritizer
#   │   ├─► product-trend-researcher
#   │   ├─► project-management-experiment-tracker
#   │   ├─► project-management-jira-workflow-steward
#   │   ├─► project-management-project-shepherd
#   │   ├─► project-management-studio-operations
#   │   ├─► project-management-studio-producer
#   │   └─► project-manager-senior
#   └─► vp-sales
#       ├─► sales-account-strategist
#       ├─► sales-coach
#       ├─► sales-deal-strategist
#       ├─► sales-discovery-coach
#       ├─► sales-engineer
#       ├─► sales-outbound-strategist
#       ├─► sales-pipeline-analyst
#       └─► sales-proposal-strategist
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/agency-agents/team.rb \
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
academic_anthropologist = member("academic-anthropologist",
           "Anthropologist — You are the Anthropologist at Agency Agents, part of " \
           "the Specialized Operations division reporting to the Chief of Staff.")

academic_geographer = member("academic-geographer",
           "Geographer — You are the Geographer at Agency Agents, part of the " \
           "Specialized Operations division reporting to the Chief of Staff.")

academic_historian = member("academic-historian",
           "Historian — You are the Historian at Agency Agents, part of the " \
           "Specialized Operations division reporting to the Chief of Staff.")

academic_narratologist = member("academic-narratologist",
           "Narratologist — You are the Narratologist at Agency Agents, part of the " \
           "Specialized Operations division reporting to the Chief of Staff.")

academic_psychologist = member("academic-psychologist",
           "Psychologist — You are the Psychologist at Agency Agents, part of the " \
           "Specialized Operations division reporting to the Chief of Staff.")

accounts_payable_agent = member("accounts-payable-agent",
           "Accounts Payable Agent — You are the Accounts Payable Agent at Agency " \
           "Agents, part of the Specialized Operations division reporting to the " \
           "Chief of Staff.")

agentic_identity_trust = member("agentic-identity-trust",
           "Agentic Identity & Trust Architect — You are the Agentic Identity & " \
           "Trust Architect at Agency Agents, part of the Specialized Operations " \
           "division reporting to the Chief of Staff.")

agents_orchestrator = member("agents-orchestrator",
           "Agents Orchestrator — You are the Agents Orchestrator at Agency Agents, " \
           "part of the Specialized Operations division reporting to the Chief of " \
           "Staff.")

automation_governance_architect = member("automation-governance-architect",
           "Automation Governance Architect — You are the Automation Governance " \
           "Architect at Agency Agents, part of the Specialized Operations division " \
           "reporting to the Chief of Staff.")

blockchain_security_auditor = member("blockchain-security-auditor",
           "Blockchain Security Auditor — You are the Blockchain Security Auditor at " \
           "Agency Agents, part of the Specialized Operations division reporting to " \
           "the Chief of Staff.")

compliance_auditor = member("compliance-auditor",
           "Compliance Auditor — You are the Compliance Auditor at Agency Agents, " \
           "part of the Specialized Operations division reporting to the Chief of " \
           "Staff.")

corporate_training_designer = member("corporate-training-designer",
           "Corporate Training Designer — You are the Corporate Training Designer at " \
           "Agency Agents, part of the Specialized Operations division reporting to " \
           "the Chief of Staff.")

data_consolidation_agent = member("data-consolidation-agent",
           "Data Consolidation Agent — You are the Data Consolidation Agent at " \
           "Agency Agents, part of the Specialized Operations division reporting to " \
           "the Chief of Staff.")

government_digital_presales_consultant = member("government-digital-presales-consultant",
           "Government Digital Presales Consultant — You are the Government Digital " \
           "Presales Consultant at Agency Agents, part of the Specialized Operations " \
           "division reporting to the Chief of Staff.")

healthcare_marketing_compliance = member("healthcare-marketing-compliance",
           "Healthcare Marketing Compliance Specialist — You are the Healthcare " \
           "Marketing Compliance Specialist at Agency Agents, part of the " \
           "Specialized Operations division reporting to the Chief of Staff.")

identity_graph_operator = member("identity-graph-operator",
           "Identity Graph Operator — You are the Identity Graph Operator at Agency " \
           "Agents, part of the Specialized Operations division reporting to the " \
           "Chief of Staff.")

lsp_index_engineer = member("lsp-index-engineer",
           "LSP/Index Engineer — You are the LSP/Index Engineer at Agency Agents, " \
           "part of the Specialized Operations division reporting to the Chief of " \
           "Staff.")

recruitment_specialist = member("recruitment-specialist",
           "Recruitment Specialist — You are the Recruitment Specialist at Agency " \
           "Agents, part of the Specialized Operations division reporting to the " \
           "Chief of Staff.")

report_distribution_agent = member("report-distribution-agent",
           "Report Distribution Agent — You are the Report Distribution Agent at " \
           "Agency Agents, part of the Specialized Operations division reporting to " \
           "the Chief of Staff.")

sales_data_extraction_agent = member("sales-data-extraction-agent",
           "Sales Data Extraction Agent — You are the Sales Data Extraction Agent at " \
           "Agency Agents, part of the Specialized Operations division reporting to " \
           "the Chief of Staff.")

specialized_cultural_intelligence_strategist = member("specialized-cultural-intelligence-strategist",
           "Cultural Intelligence Strategist — You are the Cultural Intelligence " \
           "Strategist at Agency Agents, part of the Specialized Operations division " \
           "reporting to the Chief of Staff.")

specialized_developer_advocate = member("specialized-developer-advocate",
           "Developer Advocate — You are the Developer Advocate at Agency Agents, " \
           "part of the Specialized Operations division reporting to the Chief of " \
           "Staff.")

specialized_document_generator = member("specialized-document-generator",
           "Document Generator — You are the Document Generator at Agency Agents, " \
           "part of the Specialized Operations division reporting to the Chief of " \
           "Staff.")

specialized_french_consulting_market = member("specialized-french-consulting-market",
           "French Consulting Market Navigator — You are the French Consulting " \
           "Market Navigator at Agency Agents, part of the Specialized Operations " \
           "division reporting to the Chief of Staff.")

specialized_korean_business_navigator = member("specialized-korean-business-navigator",
           "Korean Business Navigator — You are the Korean Business Navigator at " \
           "Agency Agents, part of the Specialized Operations division reporting to " \
           "the Chief of Staff.")

specialized_mcp_builder = member("specialized-mcp-builder",
           "MCP Builder — You are the MCP Builder at Agency Agents, part of the " \
           "Specialized Operations division reporting to the Chief of Staff.")

specialized_model_qa = member("specialized-model-qa",
           "Model QA Specialist — You are the Model QA Specialist at Agency Agents, " \
           "part of the Specialized Operations division reporting to the Chief of " \
           "Staff.")

specialized_salesforce_architect = member("specialized-salesforce-architect",
           "Salesforce Architect — You are the Salesforce Architect at Agency " \
           "Agents, part of the Specialized Operations division reporting to the " \
           "Chief of Staff.")

specialized_workflow_architect = member("specialized-workflow-architect",
           "Workflow Architect — You are the Workflow Architect at Agency Agents, " \
           "part of the Specialized Operations division reporting to the Chief of " \
           "Staff.")

study_abroad_advisor = member("study-abroad-advisor",
           "Study Abroad Advisor — You are the Study Abroad Advisor at Agency " \
           "Agents, part of the Specialized Operations division reporting to the " \
           "Chief of Staff.")

supply_chain_strategist = member("supply-chain-strategist",
           "Supply Chain Strategist — You are the Supply Chain Strategist at Agency " \
           "Agents, part of the Specialized Operations division reporting to the " \
           "Chief of Staff.")

zk_steward = member("zk-steward",
           "ZK Steward — You are the ZK Steward at Agency Agents, part of the " \
           "Specialized Operations division reporting to the Chief of Staff.")

chief_of_staff = member("chief-of-staff",
           "Chief of Staff — Cross-division requests for specialized expertise, " \
           "compliance and governance needs, and academic research consultations.",
           reports: [academic_anthropologist, academic_geographer, academic_historian, academic_narratologist, academic_psychologist, accounts_payable_agent, agentic_identity_trust, agents_orchestrator, automation_governance_architect, blockchain_security_auditor, compliance_auditor, corporate_training_designer, data_consolidation_agent, government_digital_presales_consultant, healthcare_marketing_compliance, identity_graph_operator, lsp_index_engineer, recruitment_specialist, report_distribution_agent, sales_data_extraction_agent, specialized_cultural_intelligence_strategist, specialized_developer_advocate, specialized_document_generator, specialized_french_consulting_market, specialized_korean_business_navigator, specialized_mcp_builder, specialized_model_qa, specialized_salesforce_architect, specialized_workflow_architect, study_abroad_advisor, supply_chain_strategist, zk_steward])

marketing_ai_citation_strategist = member("marketing-ai-citation-strategist",
           "AI Citation Strategist — You are the AI Citation Strategist at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

marketing_app_store_optimizer = member("marketing-app-store-optimizer",
           "App Store Optimizer — You are the App Store Optimizer at Agency Agents, " \
           "part of the Marketing & Paid Media division reporting to the Chief " \
           "Marketing Officer.")

marketing_baidu_seo_specialist = member("marketing-baidu-seo-specialist",
           "Baidu SEO Specialist — You are the Baidu SEO Specialist at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

marketing_bilibili_content_strategist = member("marketing-bilibili-content-strategist",
           "Bilibili Content Strategist — You are the Bilibili Content Strategist at " \
           "Agency Agents, part of the Marketing & Paid Media division reporting to " \
           "the Chief Marketing Officer.")

marketing_book_co_author = member("marketing-book-co-author",
           "Book Co-Author — You are the Book Co-Author at Agency Agents, part of " \
           "the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_carousel_growth_engine = member("marketing-carousel-growth-engine",
           "Carousel Growth Engine — You are the Carousel Growth Engine at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

marketing_china_ecommerce_operator = member("marketing-china-ecommerce-operator",
           "China E-Commerce Operator — You are the China E-Commerce Operator at " \
           "Agency Agents, part of the Marketing & Paid Media division reporting to " \
           "the Chief Marketing Officer.")

marketing_content_creator = member("marketing-content-creator",
           "Content Creator — You are the Content Creator at Agency Agents, part of " \
           "the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_cross_border_ecommerce = member("marketing-cross-border-ecommerce",
           "Cross-Border E-Commerce Specialist — You are the Cross-Border E-Commerce " \
           "Specialist at Agency Agents, part of the Marketing & Paid Media division " \
           "reporting to the Chief Marketing Officer.")

marketing_douyin_strategist = member("marketing-douyin-strategist",
           "Douyin Strategist — You are the Douyin Strategist at Agency Agents, part " \
           "of the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_growth_hacker = member("marketing-growth-hacker",
           "Growth Hacker — You are the Growth Hacker at Agency Agents, part of the " \
           "Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_instagram_curator = member("marketing-instagram-curator",
           "Instagram Curator — You are the Instagram Curator at Agency Agents, part " \
           "of the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_kuaishou_strategist = member("marketing-kuaishou-strategist",
           "Kuaishou Strategist — You are the Kuaishou Strategist at Agency Agents, " \
           "part of the Marketing & Paid Media division reporting to the Chief " \
           "Marketing Officer.")

marketing_linkedin_content_creator = member("marketing-linkedin-content-creator",
           "LinkedIn Content Creator — You are the LinkedIn Content Creator at " \
           "Agency Agents, part of the Marketing & Paid Media division reporting to " \
           "the Chief Marketing Officer.")

marketing_livestream_commerce_coach = member("marketing-livestream-commerce-coach",
           "Livestream Commerce Coach — You are the Livestream Commerce Coach at " \
           "Agency Agents, part of the Marketing & Paid Media division reporting to " \
           "the Chief Marketing Officer.")

marketing_podcast_strategist = member("marketing-podcast-strategist",
           "Podcast Strategist — You are the Podcast Strategist at Agency Agents, " \
           "part of the Marketing & Paid Media division reporting to the Chief " \
           "Marketing Officer.")

marketing_private_domain_operator = member("marketing-private-domain-operator",
           "Private Domain Operator — You are the Private Domain Operator at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

marketing_reddit_community_builder = member("marketing-reddit-community-builder",
           "Reddit Community Builder — You are the Reddit Community Builder at " \
           "Agency Agents, part of the Marketing & Paid Media division reporting to " \
           "the Chief Marketing Officer.")

marketing_seo_specialist = member("marketing-seo-specialist",
           "SEO Specialist — You are the SEO Specialist at Agency Agents, part of " \
           "the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_short_video_editing_coach = member("marketing-short-video-editing-coach",
           "Short-Video Editing Coach — You are the Short-Video Editing Coach at " \
           "Agency Agents, part of the Marketing & Paid Media division reporting to " \
           "the Chief Marketing Officer.")

marketing_social_media_strategist = member("marketing-social-media-strategist",
           "Social Media Strategist — You are the Social Media Strategist at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

marketing_tiktok_strategist = member("marketing-tiktok-strategist",
           "TikTok Strategist — You are the TikTok Strategist at Agency Agents, part " \
           "of the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_twitter_engager = member("marketing-twitter-engager",
           "Twitter Engager — You are the Twitter Engager at Agency Agents, part of " \
           "the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_wechat_official_account = member("marketing-wechat-official-account",
           "WeChat Official Account Manager — You are the WeChat Official Account " \
           "Manager at Agency Agents, part of the Marketing & Paid Media division " \
           "reporting to the Chief Marketing Officer.")

marketing_weibo_strategist = member("marketing-weibo-strategist",
           "Weibo Strategist — You are the Weibo Strategist at Agency Agents, part " \
           "of the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

marketing_xiaohongshu_specialist = member("marketing-xiaohongshu-specialist",
           "Xiaohongshu Specialist — You are the Xiaohongshu Specialist at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

marketing_zhihu_strategist = member("marketing-zhihu-strategist",
           "Zhihu Strategist — You are the Zhihu Strategist at Agency Agents, part " \
           "of the Marketing & Paid Media division reporting to the Chief Marketing " \
           "Officer.")

paid_media_auditor = member("paid-media-auditor",
           "Paid Media Auditor — You are the Paid Media Auditor at Agency Agents, " \
           "part of the Marketing & Paid Media division reporting to the Chief " \
           "Marketing Officer.")

paid_media_creative_strategist = member("paid-media-creative-strategist",
           "Ad Creative Strategist — You are the Ad Creative Strategist at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

paid_media_paid_social_strategist = member("paid-media-paid-social-strategist",
           "Paid Social Strategist — You are the Paid Social Strategist at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

paid_media_ppc_strategist = member("paid-media-ppc-strategist",
           "PPC Campaign Strategist — You are the PPC Campaign Strategist at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

paid_media_programmatic_buyer = member("paid-media-programmatic-buyer",
           "Programmatic & Display Buyer — You are the Programmatic & Display Buyer " \
           "at Agency Agents, part of the Marketing & Paid Media division reporting " \
           "to the Chief Marketing Officer.")

paid_media_search_query_analyst = member("paid-media-search-query-analyst",
           "Search Query Analyst — You are the Search Query Analyst at Agency " \
           "Agents, part of the Marketing & Paid Media division reporting to the " \
           "Chief Marketing Officer.")

paid_media_tracking_specialist = member("paid-media-tracking-specialist",
           "Tracking & Measurement Specialist — You are the Tracking & Measurement " \
           "Specialist at Agency Agents, part of the Marketing & Paid Media division " \
           "reporting to the Chief Marketing Officer.")

cmo = member("cmo",
           "Chief Marketing Officer — Strategic marketing initiatives, product " \
           "launches, brand campaigns, and demand generation targets from " \
           "leadership.",
           reports: [marketing_ai_citation_strategist, marketing_app_store_optimizer, marketing_baidu_seo_specialist, marketing_bilibili_content_strategist, marketing_book_co_author, marketing_carousel_growth_engine, marketing_china_ecommerce_operator, marketing_content_creator, marketing_cross_border_ecommerce, marketing_douyin_strategist, marketing_growth_hacker, marketing_instagram_curator, marketing_kuaishou_strategist, marketing_linkedin_content_creator, marketing_livestream_commerce_coach, marketing_podcast_strategist, marketing_private_domain_operator, marketing_reddit_community_builder, marketing_seo_specialist, marketing_short_video_editing_coach, marketing_social_media_strategist, marketing_tiktok_strategist, marketing_twitter_engager, marketing_wechat_official_account, marketing_weibo_strategist, marketing_xiaohongshu_specialist, marketing_zhihu_strategist, paid_media_auditor, paid_media_creative_strategist, paid_media_paid_social_strategist, paid_media_ppc_strategist, paid_media_programmatic_buyer, paid_media_search_query_analyst, paid_media_tracking_specialist])

design_brand_guardian = member("design-brand-guardian",
           "Brand Guardian — You are the Brand Guardian at Agency Agents, part of " \
           "the Design division reporting to the Creative Director.")

design_image_prompt_engineer = member("design-image-prompt-engineer",
           "Image Prompt Engineer — You are the Image Prompt Engineer at Agency " \
           "Agents, part of the Design division reporting to the Creative Director.")

design_inclusive_visuals_specialist = member("design-inclusive-visuals-specialist",
           "Inclusive Visuals Specialist — You are the Inclusive Visuals Specialist " \
           "at Agency Agents, part of the Design division reporting to the Creative " \
           "Director.")

design_ui_designer = member("design-ui-designer",
           "UI Designer — You are the UI Designer at Agency Agents, part of the " \
           "Design division reporting to the Creative Director.")

design_ux_architect = member("design-ux-architect",
           "UX Architect — You are the UX Architect at Agency Agents, part of the " \
           "Design division reporting to the Creative Director.")

design_ux_researcher = member("design-ux-researcher",
           "UX Researcher — You are the UX Researcher at Agency Agents, part of the " \
           "Design division reporting to the Creative Director.")

design_visual_storyteller = member("design-visual-storyteller",
           "Visual Storyteller — You are the Visual Storyteller at Agency Agents, " \
           "part of the Design division reporting to the Creative Director.")

design_whimsy_injector = member("design-whimsy-injector",
           "Whimsy Injector — You are the Whimsy Injector at Agency Agents, part of " \
           "the Design division reporting to the Creative Director.")

creative_director = member("creative-director",
           "Creative Director — Creative briefs from leadership, design requests " \
           "from product and marketing, and brand-level initiatives.",
           reports: [design_brand_guardian, design_image_prompt_engineer, design_inclusive_visuals_specialist, design_ui_designer, design_ux_architect, design_ux_researcher, design_visual_storyteller, design_whimsy_injector])

blender_addon_engineer = member("blender-addon-engineer",
           "Blender Add-on Engineer — You are the Blender Add-on Engineer at Agency " \
           "Agents, part of the Game Development division reporting to the Game " \
           "Development Director.")

game_audio_engineer = member("game-audio-engineer",
           "Game Audio Engineer — You are the Game Audio Engineer at Agency Agents, " \
           "part of the Game Development division reporting to the Game Development " \
           "Director.")

game_designer = member("game-designer",
           "Game Designer — You are the Game Designer at Agency Agents, part of the " \
           "Game Development division reporting to the Game Development Director.")

godot_gameplay_scripter = member("godot-gameplay-scripter",
           "Godot Gameplay Scripter — You are the Godot Gameplay Scripter at Agency " \
           "Agents, part of the Game Development division reporting to the Game " \
           "Development Director.")

godot_multiplayer_engineer = member("godot-multiplayer-engineer",
           "Godot Multiplayer Engineer — You are the Godot Multiplayer Engineer at " \
           "Agency Agents, part of the Game Development division reporting to the " \
           "Game Development Director.")

godot_shader_developer = member("godot-shader-developer",
           "Godot Shader Developer — You are the Godot Shader Developer at Agency " \
           "Agents, part of the Game Development division reporting to the Game " \
           "Development Director.")

level_designer = member("level-designer",
           "Level Designer — You are the Level Designer at Agency Agents, part of " \
           "the Game Development division reporting to the Game Development " \
           "Director.")

narrative_designer = member("narrative-designer",
           "Narrative Designer — You are the Narrative Designer at Agency Agents, " \
           "part of the Game Development division reporting to the Game Development " \
           "Director.")

roblox_avatar_creator = member("roblox-avatar-creator",
           "Roblox Avatar Creator — You are the Roblox Avatar Creator at Agency " \
           "Agents, part of the Game Development division reporting to the Game " \
           "Development Director.")

roblox_experience_designer = member("roblox-experience-designer",
           "Roblox Experience Designer — You are the Roblox Experience Designer at " \
           "Agency Agents, part of the Game Development division reporting to the " \
           "Game Development Director.")

roblox_systems_scripter = member("roblox-systems-scripter",
           "Roblox Systems Scripter — You are the Roblox Systems Scripter at Agency " \
           "Agents, part of the Game Development division reporting to the Game " \
           "Development Director.")

technical_artist = member("technical-artist",
           "Technical Artist — You are the Technical Artist at Agency Agents, part " \
           "of the Game Development division reporting to the Game Development " \
           "Director.")

unity_architect = member("unity-architect",
           "Unity Architect — You are the Unity Architect at Agency Agents, part of " \
           "the Game Development division reporting to the Game Development " \
           "Director.")

unity_editor_tool_developer = member("unity-editor-tool-developer",
           "Unity Editor Tool Developer — You are the Unity Editor Tool Developer at " \
           "Agency Agents, part of the Game Development division reporting to the " \
           "Game Development Director.")

unity_multiplayer_engineer = member("unity-multiplayer-engineer",
           "Unity Multiplayer Engineer — You are the Unity Multiplayer Engineer at " \
           "Agency Agents, part of the Game Development division reporting to the " \
           "Game Development Director.")

unity_shader_graph_artist = member("unity-shader-graph-artist",
           "Unity Shader Graph Artist — You are the Unity Shader Graph Artist at " \
           "Agency Agents, part of the Game Development division reporting to the " \
           "Game Development Director.")

unreal_multiplayer_architect = member("unreal-multiplayer-architect",
           "Unreal Multiplayer Architect — You are the Unreal Multiplayer Architect " \
           "at Agency Agents, part of the Game Development division reporting to the " \
           "Game Development Director.")

unreal_systems_engineer = member("unreal-systems-engineer",
           "Unreal Systems Engineer — You are the Unreal Systems Engineer at Agency " \
           "Agents, part of the Game Development division reporting to the Game " \
           "Development Director.")

unreal_technical_artist = member("unreal-technical-artist",
           "Unreal Technical Artist — You are the Unreal Technical Artist at Agency " \
           "Agents, part of the Game Development division reporting to the Game " \
           "Development Director.")

unreal_world_builder = member("unreal-world-builder",
           "Unreal World Builder — You are the Unreal World Builder at Agency " \
           "Agents, part of the Game Development division reporting to the Game " \
           "Development Director.")

game_dev_director = member("game-dev-director",
           "Game Development Director — Game development projects, engine-specific " \
           "technical challenges, and creative production requests from leadership.",
           reports: [blender_addon_engineer, game_audio_engineer, game_designer, godot_gameplay_scripter, godot_multiplayer_engineer, godot_shader_developer, level_designer, narrative_designer, roblox_avatar_creator, roblox_experience_designer, roblox_systems_scripter, technical_artist, unity_architect, unity_editor_tool_developer, unity_multiplayer_engineer, unity_shader_graph_artist, unreal_multiplayer_architect, unreal_systems_engineer, unreal_technical_artist, unreal_world_builder])

engineering_ai_data_remediation_engineer = member("engineering-ai-data-remediation-engineer",
           "AI Data Remediation Engineer — You are the AI Data Remediation Engineer " \
           "at Agency Agents, part of the Engineering division reporting to the VP " \
           "of Engineering.")

engineering_ai_engineer = member("engineering-ai-engineer",
           "AI Engineer — You are the AI Engineer at Agency Agents, part of the " \
           "Engineering division reporting to the VP of Engineering.")

engineering_autonomous_optimization_architect = member("engineering-autonomous-optimization-architect",
           "Autonomous Optimization Architect — You are the Autonomous Optimization " \
           "Architect at Agency Agents, part of the Engineering division reporting " \
           "to the VP of Engineering.")

engineering_backend_architect = member("engineering-backend-architect",
           "Backend Architect — You are the Backend Architect at Agency Agents, part " \
           "of the Engineering division reporting to the VP of Engineering.")

engineering_code_reviewer = member("engineering-code-reviewer",
           "Code Reviewer — You are the Code Reviewer at Agency Agents, part of the " \
           "Engineering division reporting to the VP of Engineering.")

engineering_data_engineer = member("engineering-data-engineer",
           "Data Engineer — You are the Data Engineer at Agency Agents, part of the " \
           "Engineering division reporting to the VP of Engineering.")

engineering_database_optimizer = member("engineering-database-optimizer",
           "Database Optimizer — You are the Database Optimizer at Agency Agents, " \
           "part of the Engineering division reporting to the VP of Engineering.")

engineering_devops_automator = member("engineering-devops-automator",
           "DevOps Automator — You are the DevOps Automator at Agency Agents, part " \
           "of the Engineering division reporting to the VP of Engineering.")

engineering_embedded_firmware_engineer = member("engineering-embedded-firmware-engineer",
           "Embedded Firmware Engineer — You are the Embedded Firmware Engineer at " \
           "Agency Agents, part of the Engineering division reporting to the VP of " \
           "Engineering.")

engineering_feishu_integration_developer = member("engineering-feishu-integration-developer",
           "Feishu Integration Developer — You are the Feishu Integration Developer " \
           "at Agency Agents, part of the Engineering division reporting to the VP " \
           "of Engineering.")

engineering_frontend_developer = member("engineering-frontend-developer",
           "Frontend Developer — You are the Frontend Developer at Agency Agents, " \
           "part of the Engineering division reporting to the VP of Engineering.")

engineering_git_workflow_master = member("engineering-git-workflow-master",
           "Git Workflow Master — You are the Git Workflow Master at Agency Agents, " \
           "part of the Engineering division reporting to the VP of Engineering.")

engineering_incident_response_commander = member("engineering-incident-response-commander",
           "Incident Response Commander — You are the Incident Response Commander at " \
           "Agency Agents, part of the Engineering division reporting to the VP of " \
           "Engineering.")

engineering_mobile_app_builder = member("engineering-mobile-app-builder",
           "Mobile App Builder — You are the Mobile App Builder at Agency Agents, " \
           "part of the Engineering division reporting to the VP of Engineering.")

engineering_rapid_prototyper = member("engineering-rapid-prototyper",
           "Rapid Prototyper — You are the Rapid Prototyper at Agency Agents, part " \
           "of the Engineering division reporting to the VP of Engineering.")

engineering_security_engineer = member("engineering-security-engineer",
           "Security Engineer — You are the Security Engineer at Agency Agents, part " \
           "of the Engineering division reporting to the VP of Engineering.")

engineering_senior_developer = member("engineering-senior-developer",
           "Senior Developer — You are the Senior Developer at Agency Agents, part " \
           "of the Engineering division reporting to the VP of Engineering.")

engineering_software_architect = member("engineering-software-architect",
           "Software Architect — You are the Software Architect at Agency Agents, " \
           "part of the Engineering division reporting to the VP of Engineering.")

engineering_solidity_smart_contract_engineer = member("engineering-solidity-smart-contract-engineer",
           "Solidity Smart Contract Engineer — You are the Solidity Smart Contract " \
           "Engineer at Agency Agents, part of the Engineering division reporting to " \
           "the VP of Engineering.")

engineering_sre = member("engineering-sre",
           "SRE (Site Reliability Engineer) — You are the SRE (Site Reliability " \
           "Engineer) at Agency Agents, part of the Engineering division reporting " \
           "to the VP of Engineering.")

engineering_technical_writer = member("engineering-technical-writer",
           "Technical Writer — You are the Technical Writer at Agency Agents, part " \
           "of the Engineering division reporting to the VP of Engineering.")

engineering_threat_detection_engineer = member("engineering-threat-detection-engineer",
           "Threat Detection Engineer — You are the Threat Detection Engineer at " \
           "Agency Agents, part of the Engineering division reporting to the VP of " \
           "Engineering.")

engineering_wechat_mini_program_developer = member("engineering-wechat-mini-program-developer",
           "WeChat Mini Program Developer — You are the WeChat Mini Program " \
           "Developer at Agency Agents, part of the Engineering division reporting " \
           "to the VP of Engineering.")

testing_accessibility_auditor = member("testing-accessibility-auditor",
           "Accessibility Auditor — You are the Accessibility Auditor at Agency " \
           "Agents, part of the Quality Assurance division reporting to the QA " \
           "Director.")

testing_api_tester = member("testing-api-tester",
           "API Tester — You are the API Tester at Agency Agents, part of the " \
           "Quality Assurance division reporting to the QA Director.")

testing_evidence_collector = member("testing-evidence-collector",
           "Evidence Collector — You are the Evidence Collector at Agency Agents, " \
           "part of the Quality Assurance division reporting to the QA Director.")

testing_performance_benchmarker = member("testing-performance-benchmarker",
           "Performance Benchmarker — You are the Performance Benchmarker at Agency " \
           "Agents, part of the Quality Assurance division reporting to the QA " \
           "Director.")

testing_reality_checker = member("testing-reality-checker",
           "Reality Checker — You are the Reality Checker at Agency Agents, part of " \
           "the Quality Assurance division reporting to the QA Director.")

testing_test_results_analyzer = member("testing-test-results-analyzer",
           "Test Results Analyzer — You are the Test Results Analyzer at Agency " \
           "Agents, part of the Quality Assurance division reporting to the QA " \
           "Director.")

testing_tool_evaluator = member("testing-tool-evaluator",
           "Tool Evaluator — You are the Tool Evaluator at Agency Agents, part of " \
           "the Quality Assurance division reporting to the QA Director.")

testing_workflow_optimizer = member("testing-workflow-optimizer",
           "Workflow Optimizer — You are the Workflow Optimizer at Agency Agents, " \
           "part of the Quality Assurance division reporting to the QA Director.")

qa_director = member("qa-director",
           "QA Director — Engineering deliverables ready for verification, quality " \
           "gate checkpoints, and production readiness reviews.",
           reports: [testing_accessibility_auditor, testing_api_tester, testing_evidence_collector, testing_performance_benchmarker, testing_reality_checker, testing_test_results_analyzer, testing_tool_evaluator, testing_workflow_optimizer])

macos_spatial_metal_engineer = member("macos-spatial-metal-engineer",
           "macOS Spatial/Metal Engineer — You are the macOS Spatial/Metal Engineer " \
           "at Agency Agents, part of the Spatial Computing & XR division reporting " \
           "to the XR Director.")

terminal_integration_specialist = member("terminal-integration-specialist",
           "Terminal Integration Specialist — You are the Terminal Integration " \
           "Specialist at Agency Agents, part of the Spatial Computing & XR division " \
           "reporting to the XR Director.")

visionos_spatial_engineer = member("visionos-spatial-engineer",
           "visionOS Spatial Engineer — You are the visionOS Spatial Engineer at " \
           "Agency Agents, part of the Spatial Computing & XR division reporting to " \
           "the XR Director.")

xr_cockpit_interaction_specialist = member("xr-cockpit-interaction-specialist",
           "XR Cockpit Interaction Specialist — You are the XR Cockpit Interaction " \
           "Specialist at Agency Agents, part of the Spatial Computing & XR division " \
           "reporting to the XR Director.")

xr_immersive_developer = member("xr-immersive-developer",
           "XR Immersive Developer — You are the XR Immersive Developer at Agency " \
           "Agents, part of the Spatial Computing & XR division reporting to the XR " \
           "Director.")

xr_interface_architect = member("xr-interface-architect",
           "XR Interface Architect — You are the XR Interface Architect at Agency " \
           "Agents, part of the Spatial Computing & XR division reporting to the XR " \
           "Director.")

xr_director = member("xr-director",
           "XR Director — Spatial computing initiatives, visionOS projects, WebXR " \
           "development, and immersive experience requests.",
           reports: [macos_spatial_metal_engineer, terminal_integration_specialist, visionos_spatial_engineer, xr_cockpit_interaction_specialist, xr_immersive_developer, xr_interface_architect])

vp_engineering = member("vp-engineering",
           "VP of Engineering & CTO — Technical initiatives from the Managing " \
           "Director, feature requests via VP of Product, infrastructure needs, and " \
           "engineering escalations from your team.",
           reports: [engineering_ai_data_remediation_engineer, engineering_ai_engineer, engineering_autonomous_optimization_architect, engineering_backend_architect, engineering_code_reviewer, engineering_data_engineer, engineering_database_optimizer, engineering_devops_automator, engineering_embedded_firmware_engineer, engineering_feishu_integration_developer, engineering_frontend_developer, engineering_git_workflow_master, engineering_incident_response_commander, engineering_mobile_app_builder, engineering_rapid_prototyper, engineering_security_engineer, engineering_senior_developer, engineering_software_architect, engineering_solidity_smart_contract_engineer, engineering_sre, engineering_technical_writer, engineering_threat_detection_engineer, engineering_wechat_mini_program_developer, qa_director, xr_director])

support_analytics_reporter = member("support-analytics-reporter",
           "Analytics Reporter — You are the Analytics Reporter at Agency Agents, " \
           "part of the Operations & Support division reporting to the VP of " \
           "Operations.")

support_executive_summary_generator = member("support-executive-summary-generator",
           "Executive Summary Generator — You are the Executive Summary Generator at " \
           "Agency Agents, part of the Operations & Support division reporting to " \
           "the VP of Operations.")

support_finance_tracker = member("support-finance-tracker",
           "Finance Tracker — You are the Finance Tracker at Agency Agents, part of " \
           "the Operations & Support division reporting to the VP of Operations.")

support_infrastructure_maintainer = member("support-infrastructure-maintainer",
           "Infrastructure Maintainer — You are the Infrastructure Maintainer at " \
           "Agency Agents, part of the Operations & Support division reporting to " \
           "the VP of Operations.")

support_legal_compliance_checker = member("support-legal-compliance-checker",
           "Legal Compliance Checker — You are the Legal Compliance Checker at " \
           "Agency Agents, part of the Operations & Support division reporting to " \
           "the VP of Operations.")

support_support_responder = member("support-support-responder",
           "Support Responder — You are the Support Responder at Agency Agents, part " \
           "of the Operations & Support division reporting to the VP of Operations.")

vp_operations = member("vp-operations",
           "VP of Operations — Operational needs from all divisions, compliance " \
           "requirements, financial reporting cycles, and customer support requests.",
           reports: [support_analytics_reporter, support_executive_summary_generator, support_finance_tracker, support_infrastructure_maintainer, support_legal_compliance_checker, support_support_responder])

product_behavioral_nudge_engine = member("product-behavioral-nudge-engine",
           "Behavioral Nudge Engine — You are the Behavioral Nudge Engine at Agency " \
           "Agents, part of the Product & Project Management division reporting to " \
           "the VP of Product.")

product_feedback_synthesizer = member("product-feedback-synthesizer",
           "Feedback Synthesizer — You are the Feedback Synthesizer at Agency " \
           "Agents, part of the Product & Project Management division reporting to " \
           "the VP of Product.")

product_manager = member("product-manager",
           "Product Manager — You are the Product Manager at Agency Agents, part of " \
           "the Product & Project Management division reporting to the VP of " \
           "Product.")

product_sprint_prioritizer = member("product-sprint-prioritizer",
           "Sprint Prioritizer — You are the Sprint Prioritizer at Agency Agents, " \
           "part of the Product & Project Management division reporting to the VP of " \
           "Product.")

product_trend_researcher = member("product-trend-researcher",
           "Trend Researcher — You are the Trend Researcher at Agency Agents, part " \
           "of the Product & Project Management division reporting to the VP of " \
           "Product.")

project_management_experiment_tracker = member("project-management-experiment-tracker",
           "Experiment Tracker — You are the Experiment Tracker at Agency Agents, " \
           "part of the Product & Project Management division reporting to the VP of " \
           "Product.")

project_management_jira_workflow_steward = member("project-management-jira-workflow-steward",
           "Jira Workflow Steward — You are the Jira Workflow Steward at Agency " \
           "Agents, part of the Product & Project Management division reporting to " \
           "the VP of Product.")

project_management_project_shepherd = member("project-management-project-shepherd",
           "Project Shepherd — You are the Project Shepherd at Agency Agents, part " \
           "of the Product & Project Management division reporting to the VP of " \
           "Product.")

project_management_studio_operations = member("project-management-studio-operations",
           "Studio Operations — You are the Studio Operations at Agency Agents, part " \
           "of the Product & Project Management division reporting to the VP of " \
           "Product.")

project_management_studio_producer = member("project-management-studio-producer",
           "Studio Producer — You are the Studio Producer at Agency Agents, part of " \
           "the Product & Project Management division reporting to the VP of " \
           "Product.")

project_manager_senior = member("project-manager-senior",
           "Senior Project Manager — You are the Senior Project Manager at Agency " \
           "Agents, part of the Product & Project Management division reporting to " \
           "the VP of Product.")

vp_product = member("vp-product",
           "VP of Product — Strategic objectives from the Managing Director, user " \
           "research insights, market analysis, and stakeholder requests.",
           reports: [product_behavioral_nudge_engine, product_feedback_synthesizer, product_manager, product_sprint_prioritizer, product_trend_researcher, project_management_experiment_tracker, project_management_jira_workflow_steward, project_management_project_shepherd, project_management_studio_operations, project_management_studio_producer, project_manager_senior])

sales_account_strategist = member("sales-account-strategist",
           "Account Strategist — You are the Account Strategist at Agency Agents, " \
           "part of the Sales division reporting to the VP of Sales.")

sales_coach = member("sales-coach",
           "Sales Coach — You are the Sales Coach at Agency Agents, part of the " \
           "Sales division reporting to the VP of Sales.")

sales_deal_strategist = member("sales-deal-strategist",
           "Deal Strategist — You are the Deal Strategist at Agency Agents, part of " \
           "the Sales division reporting to the VP of Sales.")

sales_discovery_coach = member("sales-discovery-coach",
           "Discovery Coach — You are the Discovery Coach at Agency Agents, part of " \
           "the Sales division reporting to the VP of Sales.")

sales_engineer = member("sales-engineer",
           "Sales Engineer — You are the Sales Engineer at Agency Agents, part of " \
           "the Sales division reporting to the VP of Sales.")

sales_outbound_strategist = member("sales-outbound-strategist",
           "Outbound Strategist — You are the Outbound Strategist at Agency Agents, " \
           "part of the Sales division reporting to the VP of Sales.")

sales_pipeline_analyst = member("sales-pipeline-analyst",
           "Pipeline Analyst — You are the Pipeline Analyst at Agency Agents, part " \
           "of the Sales division reporting to the VP of Sales.")

sales_proposal_strategist = member("sales-proposal-strategist",
           "Proposal Strategist — You are the Proposal Strategist at Agency Agents, " \
           "part of the Sales division reporting to the VP of Sales.")

vp_sales = member("vp-sales",
           "VP of Sales — Revenue targets, inbound leads from marketing, outbound " \
           "prospecting, and account expansion opportunities.",
           reports: [sales_account_strategist, sales_coach, sales_deal_strategist, sales_discovery_coach, sales_engineer, sales_outbound_strategist, sales_pipeline_analyst, sales_proposal_strategist])

TEAM = [chief_of_staff, cmo, creative_director, game_dev_director, vp_engineering, vp_operations, vp_product, vp_sales].freeze

# The Managing Director & CEO's prompt is the company description (COMPANY.md body)
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
