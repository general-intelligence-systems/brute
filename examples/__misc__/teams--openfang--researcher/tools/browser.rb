# frozen_string_literal: true

# OpenFang's browser_* tools (used by the travel-planner agent), ported from
# RightNow-AI/openfang crates/openfang-runtime/src/tool_runner.rs — tool
# names, descriptions, and parameter schemas are verbatim. The behavior
# delegates to the browser-agent port's Chrome-over-CDP driver
# (examples/ports/browser-agent/drivers/ferrum.rb), reusing one persistent
# session across tools like openfang's browser context.
#
# The driver needs the optional ferrum gem and a Chrome/Chromium binary:
#
#   bundle config set --local with browser && bundle install
#
# The session is created lazily on first use, so agents that merely declare
# browser tools load fine without the gem installed.

require "bundler/setup"
require "brute"

require "base64"
require "fileutils"
require "tmpdir"
require "uri"

require_relative "../../browser-agent/drivers/ferrum"

module OpenFang
  module Tools
    # One shared, lazily-created browser session — openfang's "persistent
    # browser session" that browser_navigate opens and browser_close ends.
    module BrowserSession
      MAX_PAGE_CHARS = 50_000

      class << self
        def driver
          @driver ||= BrowserAgent::Drivers::Ferrum.new
        end

        def close
          @driver&.quit
          @driver = nil
        end

        # Title + readable text of the current page, markdown-shaped.
        def page_markdown
          title = driver.evaluate(script: "return document.title")
          text = driver.evaluate(script: "return document.body ? document.body.innerText : ''").to_s
          text = text[0...MAX_PAGE_CHARS] + "\n...(truncated)" if text.size > MAX_PAGE_CHARS
          "# #{title}\n\n#{text}"
        end
      end
    end

    class BrowserNavigate < RubyLLM::Tool
      description "Navigate a browser to a URL. Returns the page title and readable content as markdown. Opens a persistent browser session."

      param :url, type: 'string', desc: "The URL to navigate to (http/https only)", required: true

      def name; "browser_navigate"; end

      def execute(url:)
        scheme = URI.parse(url).scheme
        return "Invalid URL scheme: #{scheme} (http/https only)" unless %w[http https].include?(scheme)

        BrowserSession.driver.goto(url: url)
        BrowserSession.page_markdown
      end
    end

    class BrowserClick < RubyLLM::Tool
      description "Click an element on the current browser page by CSS selector or visible text. Returns the resulting page state."

      param :selector, type: 'string', desc: "CSS selector (e.g., '#submit-btn', '.add-to-cart') or visible text to click", required: true

      def name; "browser_click"; end

      def execute(selector:)
        BrowserSession.driver.click(selector: selector)
        BrowserSession.page_markdown
      end
    end

    class BrowserType < RubyLLM::Tool
      description "Type text into an input field on the current browser page."

      param :selector, type: 'string', desc: %q{CSS selector for the input field (e.g., 'input[name="email"]', '#search-box')}, required: true
      param :text, type: 'string', desc: "The text to type into the field", required: true

      def name; "browser_type"; end

      def execute(selector:, text:)
        BrowserSession.driver.fill(fields: [{ "selector" => selector, "value" => text }])
        "Typed into '#{selector}'."
      end
    end

    class BrowserScreenshot < RubyLLM::Tool
      description "Take a screenshot of the current browser page. Returns a base64-encoded PNG image."

      def name; "browser_screenshot"; end

      def execute
        path = File.join(Dir.mktmpdir("openfang-screenshot"), "page.png")
        BrowserSession.driver.screenshot(path: path)
        Base64.strict_encode64(File.binread(path))
      ensure
        FileUtils.rm_rf(File.dirname(path)) if path
      end
    end

    class BrowserReadPage < RubyLLM::Tool
      description "Read the current browser page content as structured markdown. Use after clicking or navigating to see the updated page."

      def name; "browser_read_page"; end

      def execute
        BrowserSession.page_markdown
      end
    end

    class BrowserClose < RubyLLM::Tool
      description "Close the browser session. The browser will also auto-close when the agent loop ends."

      def name; "browser_close"; end

      def execute
        BrowserSession.close
        "Browser session closed."
      end
    end
  end
end
