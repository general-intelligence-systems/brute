#!/usr/bin/env ruby
# frozen_string_literal: true

# Donchitos Game Studio — a team of agents, ported from paperclipai/companies
# (companies/donchitos-game-studio).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo  (milestone-review, scope-check)
#   ├─► creative-director  (brainstorm, design-review)
#   │   ├─► art-director
#   │   │   ├─► technical-artist
#   │   │   └─► ux-designer
#   │   ├─► audio-director
#   │   │   └─► sound-designer
#   │   ├─► game-designer  (design-review, balance-check, brainstorm)
#   │   │   ├─► economy-designer
#   │   │   ├─► level-designer
#   │   │   └─► systems-designer
#   │   └─► narrative-director
#   │       ├─► world-builder
#   │       └─► writer
#   ├─► producer  (sprint-plan, scope-check, estimate, milestone-review)
#   │   ├─► accessibility-specialist
#   │   ├─► analytics-engineer
#   │   ├─► community-manager
#   │   ├─► devops-engineer
#   │   ├─► live-ops-designer
#   │   ├─► localization-lead
#   │   ├─► prototyper
#   │   ├─► release-manager  (release-checklist, changelog, patch-notes)
#   │   └─► security-engineer
#   └─► technical-director
#       ├─► lead-programmer  (code-review, architecture-decision, tech-debt)
#       │   ├─► ai-programmer
#       │   ├─► engine-programmer
#       │   ├─► gameplay-programmer
#       │   ├─► godot-specialist
#       │   │   ├─► godot-gdextension-specialist
#       │   │   ├─► godot-gdscript-specialist
#       │   │   └─► godot-shader-specialist
#       │   ├─► network-programmer
#       │   ├─► tools-programmer
#       │   ├─► ui-programmer
#       │   ├─► unity-specialist
#       │   │   ├─► unity-addressables-specialist
#       │   │   ├─► unity-dots-specialist
#       │   │   ├─► unity-shader-specialist
#       │   │   └─► unity-ui-specialist
#       │   └─► unreal-specialist
#       │       ├─► ue-blueprint-specialist
#       │       ├─► ue-gas-specialist
#       │       ├─► ue-replication-specialist
#       │       └─► ue-umg-specialist
#       ├─► performance-analyst
#       └─► qa-lead  (bug-report, release-checklist)
#           └─► qa-tester
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/donchitos-game-studio/team.rb \
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
technical_artist = member("technical-artist",
           "Technical Artist — Art-director provides visual direction and target " \
           "look for shaders and effects.; Lead-programmer and technical-director " \
           "provide technical constraints: shader model targets, performance " \
           "budgets, platform limitations.; You receive optimization requests when " \
           "scenes or assets exceed their allocated…")

ux_designer = member("ux-designer",
           "UX Designer — Art-director provides UI visual direction and style " \
           "constraints.; Game-designer provides mechanical requirements that need " \
           "player-facing interfaces.; You proactively identify UX problems in " \
           "existing flows and propose improvements.")

art_director = member("art-director",
           "Art Director — Creative-director provides the creative vision and " \
           "pillars that inform visual direction.; You translate those pillars into " \
           "concrete visual rules.; Level-designer, narrative-director, and " \
           "game-designer request visual direction for new content areas.",
           reports: [technical_artist, ux_designer])

sound_designer = member("sound-designer",
           "Sound Designer — Audio-director provides the sonic direction, sound " \
           "palettes, and mix priorities.; You receive specific SFX requests tied to " \
           "game systems, levels, or UI elements.; Game-designer and level-designer " \
           "request audio for new mechanics and encounters.")

audio_director = member("audio-director",
           "Audio Director — Creative-director provides the creative vision and " \
           "emotional targets that inform audio direction.; You translate creative " \
           "pillars into sonic rules.; Game-designer and level-designer request " \
           "audio direction for new systems and areas.",
           reports: [sound_designer])

economy_designer = member("economy-designer",
           "Economy Designer — Game-designer provides economy design parameters: " \
           "what resources exist, what the intended earning/spending ratios are, and " \
           "what the player fantasy around rewards should feel like.; " \
           "Systems-designer provides formulas that the economy must be compatible " \
           "with.; You receive balancing requests when…")

level_designer = member("level-designer",
           "Level Designer — Game-designer provides area/level briefs specifying " \
           "mechanical goals, difficulty targets, and system constraints.; " \
           "Narrative-director provides narrative purpose for each area (what story " \
           "beats happen here, what lore is embedded).; You combine both into a " \
           "unified spatial design.")

systems_designer = member("systems-designer",
           "Systems Designer — Game-designer assigns subsystem design tasks with a " \
           "brief specifying the intended player experience and constraints.; You " \
           "receive partially defined systems that need mathematical formalization.; " \
           "Game-designer or economy-designer requests formula validation or balance " \
           "analysis.")

game_designer = member("game-designer",
           "Lead Game Designer — Creative-director provides vision and pillar " \
           "direction.; You break pillars down into concrete mechanical systems and " \
           "assign subsystem work to your reports.; Other departments request " \
           "mechanical consultation (e.g., narrative-director needs a dialogue " \
           "system, art-director needs UI interaction rules).",
           reports: [economy_designer, level_designer, systems_designer])

world_builder = member("world-builder",
           "World Builder — Narrative-director provides the world framework: themes, " \
           "scale, core mysteries, and narrative constraints.; You expand that " \
           "framework into a comprehensive, internally consistent world.; " \
           "Level-designer requests lore context for specific areas.; Writer " \
           "requests lore details for dialogue and text…")

writer = member("writer",
           "Writer — Narrative-director provides narrative briefs specifying the " \
           "story beat, characters involved, emotional target, and constraints.; " \
           "Game-designer requests mechanical descriptions (ability tooltips, system " \
           "explanations).; Level-designer requests environmental text for specific " \
           "areas.")

narrative_director = member("narrative-director",
           "Narrative Director — Creative-director provides the creative vision and " \
           "thematic pillars.; You translate those pillars into narrative " \
           "frameworks.; Game-designer requests narrative support for game systems " \
           "(quest structures, progression fiction).; Level-designer requests " \
           "narrative context for areas and encounters.",
           reports: [world_builder, writer])

creative_director = member("creative-director",
           "Creative Director — You initiate creative direction at project kickoff " \
           "and revisit it at milestone reviews.; Department leads (game-designer, " \
           "art-director, audio-director, narrative-director) escalate unresolved " \
           "creative conflicts to you.; You proactively audit department output for " \
           "vision alignment.",
           reports: [art_director, audio_director, game_designer, narrative_director])

accessibility_specialist = member("accessibility-specialist",
           "Accessibility Specialist — Producer assigns accessibility milestones and " \
           "review checkpoints.; You participate in design reviews to catch " \
           "accessibility issues before implementation.; UX-designer and " \
           "game-designer consult you on interaction design and difficulty systems.; " \
           "QA-tester runs accessibility test plans you define and…")

analytics_engineer = member("analytics-engineer",
           "Analytics Engineer — Producer assigns analytics priorities and milestone " \
           "deliverables.; Game-designer and systems-designer request data to " \
           "validate or tune mechanical designs.; Economy-designer needs economic " \
           "health metrics and transaction data.; Live-ops-designer needs event " \
           "performance metrics and engagement tracking.")

community_manager = member("community-manager",
           "Community Manager — Producer approves all public communications and " \
           "assigns communication priorities.; Release-manager provides release " \
           "timing and patch contents for patch note drafting.; You proactively " \
           "monitor community channels and escalate urgent issues.; " \
           "Live-ops-designer provides event details for community…")

devops_engineer = member("devops-engineer",
           "DevOps Engineer — Producer assigns infrastructure priorities and " \
           "deadlines.; Release-manager requests release builds and deployment " \
           "support.; Lead-programmer and technical-director define branching " \
           "strategy and quality gate requirements.; Any team member can report " \
           "pipeline issues — you triage and fix them.")

live_ops_designer = member("live-ops-designer",
           "Live Operations Designer — Producer sets live ops milestones and " \
           "resource allocation.; You propose the content roadmap and cadence based " \
           "on genre best practices and player data.; Analytics-engineer provides " \
           "engagement metrics, retention curves, and event performance data.; " \
           "Community-manager relays player sentiment and…")

localization_lead = member("localization-lead",
           "Localization Lead — Producer assigns localization milestones aligned to " \
           "the release schedule.; Writer and narrative-director provide source " \
           "strings with context notes for dialogue and narrative text.; " \
           "UI-programmer and ux-designer flag new UI elements requiring localized " \
           "text.; You proactively scan for hardcoded…")

prototyper = member("prototyper",
           "Prototyper — Producer assigns prototyping tasks based on pre-production " \
           "priorities.; Game-designer requests mechanical prototypes to test game " \
           "feel before committing to a GDD.; Technical-director requests technical " \
           "feasibility prototypes for risky features.; Creative-director requests " \
           "experience prototypes to…")

release_manager = member("release-manager",
           "Release Manager — Producer sets the release schedule and milestone " \
           "targets.; You initiate the release pipeline when a build meets the " \
           "release candidate criteria.; QA-lead provides go/no-go quality gate " \
           "decisions at each pipeline stage.; Platform holders may return " \
           "certification feedback requiring fixes and…")

security_engineer = member("security-engineer",
           "Security Engineer — Producer assigns security review milestones.; " \
           "Lead-programmer requests security review for new systems or protocols.; " \
           "Network-programmer requests review of network security architecture.; " \
           "You proactively audit the codebase, infrastructure, and live services " \
           "for vulnerabilities.")

producer = member("producer",
           "Producer — You initiate sprint planning at the start of each cycle.; " \
           "Department leads surface blockers, resource conflicts, and dependency " \
           "issues to you.; Creative-director and technical-director bring scope " \
           "change requests that need schedule impact analysis.; You proactively " \
           "audit progress against the…",
           reports: [accessibility_specialist, analytics_engineer, community_manager, devops_engineer, live_ops_designer, localization_lead, prototyper, release_manager, security_engineer])

ai_programmer = member("ai-programmer",
           "AI Programmer — You receive task assignments and architectural guidance " \
           "from the lead-programmer. AI behavior specifications come from the " \
           "game-designer describing how NPCs and enemies should behave. Performance " \
           "budgets come from the performance-analyst and technical-director.")

engine_programmer = member("engine-programmer",
           "Engine Programmer — You receive architectural direction and task " \
           "assignments from the lead-programmer. Requirements flow from gameplay " \
           "needs surfaced by other programmers. Performance targets come from the " \
           "performance-analyst and technical-director.")

gameplay_programmer = member("gameplay-programmer",
           "Gameplay Programmer — You receive architectural guidance and task " \
           "assignments from the lead-programmer. Feature specifications and design " \
           "documents come from the game-designer via the lead-programmer. You work " \
           "within the architectural boundaries set by the lead-programmer and use " \
           "the engine systems provided by the…")

godot_gdextension_specialist = member("godot-gdextension-specialist",
           "GDExtension Specialist — Godot-specialist assigns GDExtension tasks when " \
           "performance requirements exceed GDScript capabilities.; Lead-programmer " \
           "identifies systems that need native implementation.; Performance-analyst " \
           "provides profiling data justifying the move from GDScript to native " \
           "code.; Technical-director approves the…")

godot_gdscript_specialist = member("godot-gdscript-specialist",
           "GDScript Specialist — Godot-specialist assigns GDScript-specific tasks " \
           "and reviews.; Programmers writing GDScript request pattern guidance and " \
           "code review.; Performance-analyst identifies GDScript bottlenecks that " \
           "need optimization.; You proactively audit the codebase for type safety " \
           "violations, anti-patterns, and…")

godot_shader_specialist = member("godot-shader-specialist",
           "Godot Shader Specialist — Godot-specialist assigns rendering tasks and " \
           "reviews shader architecture.; Art-director and technical-artist define " \
           "the visual targets that shaders must achieve.; Performance-analyst " \
           "identifies rendering bottlenecks that need shader optimization.; VFX " \
           "needs from level-designer and world-builder…")

godot_specialist = member("godot-specialist",
           "Godot Engine Lead — You receive assignments from the lead-programmer for " \
           "all Godot-related work. Other programmers consult you when working " \
           "within Godot 4. You proactively review Godot code for adherence to " \
           "engine patterns and conventions.",
           reports: [godot_gdextension_specialist, godot_gdscript_specialist, godot_shader_specialist])

network_programmer = member("network-programmer",
           "Network Programmer — You receive task assignments and architectural " \
           "guidance from the lead-programmer. Multiplayer design requirements come " \
           "from the game-designer. Performance and bandwidth targets come from the " \
           "technical-director.")

tools_programmer = member("tools-programmer",
           "Tools Programmer — You receive task assignments from the " \
           "lead-programmer. Tool requests come from across the team: artists need " \
           "content pipelines, designers need authoring tools, programmers need " \
           "debug utilities, QA needs testing harnesses. The lead-programmer " \
           "prioritizes these requests.")

ui_programmer = member("ui-programmer",
           "UI Programmer — You receive task assignments from the lead-programmer. " \
           "UI designs and wireframes come from the UI/UX designer. Gameplay events " \
           "that drive UI updates come from the gameplay-programmer. Localization " \
           "requirements come from the production team.")

unity_addressables_specialist = member("unity-addressables-specialist",
           "Unity Addressables Specialist — You receive assignments from the " \
           "unity-specialist. Asset management requirements come from the content " \
           "teams (art, design, audio) and from memory constraints on target " \
           "platforms. You design and maintain the asset loading architecture.")

unity_dots_specialist = member("unity-dots-specialist",
           "DOTS/ECS Specialist — You receive assignments from the unity-specialist. " \
           "Systems that require high-performance data-oriented processing are " \
           "routed to you. You advise on when to migrate MonoBehaviour systems to " \
           "DOTS based on performance requirements.")

unity_shader_specialist = member("unity-shader-specialist",
           "Unity Shader/VFX Specialist — You receive assignments from the " \
           "unity-specialist. Visual requirements come from the art director and " \
           "technical artist. Rendering features are requested through the " \
           "production chain. You implement the rendering techniques needed to " \
           "achieve the game's visual targets.")

unity_ui_specialist = member("unity-ui-specialist",
           "Unity UI Specialist — You receive assignments from the unity-specialist. " \
           "UI designs come from the UI/UX designer. Integration requirements come " \
           "from the ui-programmer. You implement the Unity-specific UI layer using " \
           "the appropriate UI framework.")

unity_specialist = member("unity-specialist",
           "Unity Engine Lead — You receive assignments from the lead-programmer for " \
           "all Unity-related work. Other programmers consult you when working " \
           "within Unity. You proactively review Unity code for adherence to engine " \
           "patterns and conventions.",
           reports: [unity_addressables_specialist, unity_dots_specialist, unity_shader_specialist, unity_ui_specialist])

ue_blueprint_specialist = member("ue-blueprint-specialist",
           "Blueprint Specialist — You receive assignments from the " \
           "unreal-specialist. Blueprint architecture reviews are requested by other " \
           "programmers and designers working in UE5. You proactively audit " \
           "Blueprint assets for quality and performance.")

ue_gas_specialist = member("ue-gas-specialist",
           "Gameplay Ability System Specialist — You receive assignments from the " \
           "unreal-specialist. Ability and gameplay effect requirements come from " \
           "the game-designer via the production chain. You implement the GAS " \
           "architecture that gameplay-programmer uses for combat and ability " \
           "systems.")

ue_replication_specialist = member("ue-replication-specialist",
           "UE Replication Specialist — You receive assignments from the " \
           "unreal-specialist. Multiplayer requirements come from the game-designer " \
           "and network-programmer. You implement and review all UE5 replication " \
           "code to ensure correct, performant multiplayer behavior.")

ue_umg_specialist = member("ue-umg-specialist",
           "UMG/CommonUI Specialist — You receive assignments from the " \
           "unreal-specialist. UI designs come from the UI/UX designer. Integration " \
           "requirements come from the ui-programmer. You implement the UE5-specific " \
           "UI layer using UMG and CommonUI.")

unreal_specialist = member("unreal-specialist",
           "Unreal Engine Lead — You receive assignments from the lead-programmer " \
           "for all Unreal Engine related work. Other programmers consult you when " \
           "working within UE5. You proactively review UE5 code for adherence to " \
           "engine patterns and conventions.",
           reports: [ue_blueprint_specialist, ue_gas_specialist, ue_replication_specialist, ue_umg_specialist])

lead_programmer = member("lead-programmer",
           "Lead Programmer — You receive architectural direction and technical " \
           "constraints from the technical-director. Feature specifications and " \
           "gameplay requirements come from the game-designer. You translate these " \
           "into concrete programming tasks, architectural sketches, and API " \
           "designs.",
           reports: [ai_programmer, engine_programmer, gameplay_programmer, godot_specialist, network_programmer, tools_programmer, ui_programmer, unity_specialist, unreal_specialist])

performance_analyst = member("performance-analyst",
           "Performance Analyst — You receive performance targets and priorities " \
           "from the technical-director. You proactively profile the game on a " \
           "regular cadence and after significant code changes. Other programmers " \
           "request performance analysis when they suspect bottlenecks.")

qa_tester = member("qa-tester",
           "QA Tester — You receive test plans, priority areas, and specific test " \
           "assignments from the qa-lead. When new features are completed, the " \
           "qa-lead assigns you testing tasks with clear scope and acceptance " \
           "criteria.")

qa_lead = member("qa-lead",
           "QA Lead — You receive quality targets and release criteria from the " \
           "technical-director. Feature completion notifications come from the " \
           "lead-programmer. You proactively identify areas that need testing based " \
           "on code changes, risk assessments, and historical bug patterns.",
           reports: [qa_tester])

technical_director = member("technical-director",
           "Technical Director — Creative-director and game-designer bring feature " \
           "proposals that need technical feasibility assessment.; Lead-programmer " \
           "escalates architectural decisions and unresolved technical disputes.; " \
           "Performance-analyst surfaces budget violations that require " \
           "architectural intervention.; You proactively…",
           reports: [lead_programmer, performance_analyst, qa_lead])

TEAM = [creative_director, producer, technical_director].freeze

# The Studio Head & CEO's prompt is the company description (COMPANY.md body)
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
