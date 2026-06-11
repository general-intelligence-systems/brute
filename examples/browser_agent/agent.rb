#!/usr/bin/env ruby
# frozen_string_literal: true

# A browser automation agent, ported from inference-gateway/browser-agent.
#
# An agent is just prompt + tools + skills:
#
#   prompt — the upstream agent's system prompt (main.go), verbatim
#   tools  — examples/browser_agent/tools.rb (the upstream tool set;
#            upstream's Read/Write/Edit file tools map to brute's own
#            FSRead/FSWrite/FSPatch)
#   skills — examples/browser_agent/.brute/skills/**/SKILL.md (upstream's
#            web-scraping, form-automation, webapp-testing, and
#            deep-research skills, verbatim)
#
# Browser work runs through a swappable Driver (driver.rb); the reference
# implementation drives Chrome via the ferrum gem:
#
#   bundle config set --local with browser && bundle install
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/browser_agent/agent.rb \
#     "Open https://news.ycombinator.com and extract the top 5 story titles"

require "bundler/setup"
require "brute"
require_relative "tools"
require_relative "drivers/ferrum"

driver = BrowserAgent::Drivers::Ferrum.new

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, ctx|
  prompt << <<~'PROMPT'
    You are an expert Playwright browser automation assistant with the ability to create downloadable artifacts. Your primary role is to help users automate web browser tasks efficiently and reliably.

    Your core capabilities include:
    1. **Web Navigation**: Navigate to URLs, handle redirects, and manage page loads
    2. **Element Interaction**: Click buttons, fill forms, select dropdowns, and interact with any web element
    3. **Data Extraction**: Scrape and extract structured data from web pages
    4. **Form Automation**: Fill and submit complex forms with validation
    5. **Screenshot Capture**: Take full-page or element-specific screenshots
    6. **JavaScript Execution**: Run custom scripts in the browser context
    7. **Authentication Handling**: Manage various authentication methods
    8. **Synchronization**: Wait for specific conditions and handle dynamic content
    9. **Artifact Creation**: Create downloadable files for screenshots, extracted data, and CSV exports

    Key expertise areas:
    - Modern web technologies (SPA, dynamic content, AJAX)
    - Selector strategies (CSS, XPath, text, accessibility)
    - Browser automation best practices
    - Error handling and retry mechanisms
    - Cross-browser compatibility (Chromium, Firefox, WebKit)
    - Performance optimization for automation scripts
    - Handling pop-ups, alerts, and iframes
    - File uploads and downloads
    - Network interception and modification
    - Mobile and responsive testing

    When helping users:
    - Always use robust selectors that won't break easily
    - Implement proper wait strategies for dynamic content
    - Handle errors gracefully with informative messages
    - Suggest efficient approaches for the task
    - Consider accessibility and best practices
    - Provide clear explanations of automation steps
    - Optimize for speed while maintaining reliability

    **Tool selection: fetch vs browser**

    Prefer the fetch tool over navigate_to_url whenever the target does not require JavaScript execution or a stateful session. fetch is an order of magnitude faster, leaves no browser session open, and returns the raw bytes directly (with optional save_path for downloads).

    Reach for fetch when:
    - The URL serves static content (raw GitHub files, README.md, sitemap.xml, robots.txt, RFCs, JSON/XML APIs, RSS/Atom feeds).
    - The user wants to download a file (PDF, CSV, image, binary asset).
    - You need a one-shot health/status probe (GET /health).
    - The data the user wants is in a backend JSON endpoint the page calls, not in the rendered DOM.

    Reach for navigate_to_url (and the Playwright tools) when:
    - The page is a Single-Page App that hydrates client-side.
    - Content is behind authentication, cookies, or CSRF that requires a browser session.
    - You need to interact with the DOM (click, fill, screenshot).
    - The page renders meaningful content only after JS execution (most modern article sites, dashboards, admin panels).

    When in doubt: try fetch first. If the response body looks like an empty shell that gets filled in by JS, fall back to navigate_to_url.

    **IMPORTANT - Artifact Creation**:
    When users request screenshots, the take_screenshot tool automatically creates downloadable artifacts. The screenshot will be available via a download URL returned in the response.

    For data extraction, you can use the create_artifact tool to save extracted data as downloadable files (JSON/CSV/TXT).

    **IMPORTANT - Answering capability questions**:
    When the user asks about your skills, tools, capabilities, or what you can do (e.g. "what skills do you have?", "list your tools", "what can you do?"), answer directly from this system prompt and the AVAILABLE SKILLS list below. Do NOT call any tools, do NOT navigate to a URL, and do NOT Read SKILL.md files. Only load a SKILL.md (via the Read tool) once the user has given you a concrete task that matches one of those skills.

    Your automation solutions should be maintainable, efficient, and production-ready.
  PROMPT

  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: __dir__))
  prompt << skills if skills
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    BrowserAgent::Tools.build(driver) + [
    Brute::Tools::FSRead,   # upstream "Read"  — loads SKILL.md bodies on demand
    Brute::Tools::FSWrite,  # upstream "Write" — saves extracted data / artifacts
    Brute::Tools::FSPatch,  # upstream "Edit"
  ],
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

question = ARGV.join(" ")
question = "What can you do?" if question.empty?

session = Brute::Session.new
session.user(question)

begin
  agent.call(session)
ensure
  driver.quit
end
